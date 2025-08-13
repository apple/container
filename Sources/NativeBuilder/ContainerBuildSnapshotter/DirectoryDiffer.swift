//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

public struct DirectoryDiffer: Sendable {
    private let inspector: any FileAttributeInspector
    private let fileDiffer: FileDiffer
    private let options: InspectorOptions

    public init(
        inspector: any FileAttributeInspector = DefaultFileAttributeInspector(),
        fileDiffer: FileDiffer = FileDiffer(),
        options: InspectorOptions = InspectorOptions()
    ) {
        self.inspector = inspector
        self.fileDiffer = fileDiffer
        self.options = options
    }

    // Safety: ensure no multiplicity-sensitive duplicates leak to DiffKey materialization.
    private struct ChangeKey: Hashable {
        let operation: String
        let path: BinaryPath
    }

    private func changeKey(for diff: Diff) -> ChangeKey {
        switch diff {
        case .added(let a):
            return ChangeKey(operation: "A", path: a.path)
        case .modified(let m):
            return ChangeKey(operation: "M", path: m.path)
        case .deleted(let p):
            return ChangeKey(operation: "D", path: p)
        }
    }

    private func dedupeStable(_ diffs: [Diff]) -> [Diff] {
        var seen = Set<ChangeKey>()
        var out: [Diff] = []
        out.reserveCapacity(diffs.count)
        for d in diffs {
            let k = changeKey(for: d)
            if seen.insert(k).inserted {
                out.append(d)
            }
        }
        return out
    }

    public func diff(base: URL?, target: URL) async throws -> [Diff] {
        // Scratch layer: stream additions only, with bounded concurrency.
        guard let base = base else {
            var additions: [Diff] = []
            let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)

            guard
                let enumerator = FileManager.default.enumerator(
                    at: target,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                    ],
                    options: []
                )
            else {
                throw DifferError.cannotEnumerateDirectory(target)
            }

            try await withThrowingTaskGroup(of: Diff?.self) { group in
                var inFlight = 0
                while let fileURL = enumerator.nextObject() as? URL {
                    let rel = relativePath(of: fileURL, base: target)
                    group.addTask {
                        var attrs = try await inspector.inspect(url: fileURL, options: options)
                        attrs.path = rel
                        // Device nodes (char/block) are intentionally excluded from diffs; they do not affect rebuilds.
                        if attrs.type == .characterDevice || attrs.type == .blockDevice {
                            return nil
                        }
                        return makeAdded(from: attrs, path: rel)
                    }
                    inFlight += 1
                    if inFlight >= concurrency {
                        if let d = try await group.next(), let dd = d { additions.append(dd) }
                        inFlight -= 1
                    }
                }
                while let d = try await group.next() {
                    if let dd = d { additions.append(dd) }
                }
            }

            return dedupeStable(additions).sorted(by: diffPathLessThan)
        }
        return try await diff(base: base, target: target)
    }

    private func diff(base: URL, target: URL) async throws -> [Diff] {
        var changes: [Diff] = []
        let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)

        // Pass 1: additions and modifications by streaming through target
        guard
            let targetEnum = FileManager.default.enumerator(
                at: target,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: []
            )
        else {
            throw DifferError.cannotEnumerateDirectory(target)
        }

        try await withThrowingTaskGroup(of: Diff?.self) { group in
            var inFlight = 0
            while let newURL = targetEnum.nextObject() as? URL {
                let rel = relativePath(of: newURL, base: target)
                let oldURL = base.appendingPathComponent(rel.requireString)
                group.addTask {
                    let newAttrs = try await inspector.inspect(url: newURL, options: options)
                    // Device nodes (char/block) are intentionally excluded from diffs; they do not affect rebuilds.
                    if !FileManager.default.fileExists(atPath: oldURL.path) {
                        if newAttrs.type == .characterDevice || newAttrs.type == .blockDevice {
                            return nil
                        }
                        return makeAdded(from: newAttrs, path: rel)
                    }
                    let oldAttrs = try await inspector.inspect(url: oldURL, options: options)

                    // If the old entry is a device and the new is non-device, treat as an addition of the new node.
                    // Device nodes themselves never surface in diffs.
                    if (oldAttrs.type == .characterDevice || oldAttrs.type == .blockDevice) && !(newAttrs.type == .characterDevice || newAttrs.type == .blockDevice) {
                        return makeAdded(from: newAttrs, path: rel)
                    }

                    // If the new entry is a device and the old is non-device, treat as a deletion of the old node.
                    // Device nodes themselves never surface in diffs.
                    if (newAttrs.type == .characterDevice || newAttrs.type == .blockDevice) && !(oldAttrs.type == .characterDevice || oldAttrs.type == .blockDevice) {
                        return .deleted(path: rel)
                    }

                    // If both sides are devices, ignore entirely.
                    if (newAttrs.type == .characterDevice || newAttrs.type == .blockDevice) && (oldAttrs.type == .characterDevice || oldAttrs.type == .blockDevice) {
                        return nil
                    }

                    let result = try fileDiffer.diff(
                        oldAttrs: oldAttrs,
                        newAttrs: newAttrs,
                        oldURL: oldURL,
                        newURL: newURL,
                        options: options
                    )
                    if let result {
                        return makeModified(kind: result, newAttrs: newAttrs, path: rel)
                    }
                    return nil
                }
                inFlight += 1
                if inFlight >= concurrency {
                    if let d = try await group.next(), let dd = d { changes.append(dd) }
                    inFlight -= 1
                }
            }
            while let d = try await group.next() {
                if let dd = d { changes.append(dd) }
            }
        }

        // Pass 2: deletions by streaming through base
        guard
            let baseEnum = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [] as [URLResourceKey],
                options: []
            )
        else {
            throw DifferError.cannotEnumerateDirectory(base)
        }
        try await withThrowingTaskGroup(of: Diff?.self) { group in
            var inFlight = 0
            while let oldURL = baseEnum.nextObject() as? URL {
                let rel = relativePath(of: oldURL, base: base)
                let newURL = target.appendingPathComponent(rel.requireString)
                group.addTask {
                    let exists = FileManager.default.fileExists(atPath: newURL.path)
                    if !exists {
                        // Device nodes (char/block) deletions are ignored; they do not affect rebuilds.
                        let oldAttrs = try await inspector.inspect(url: oldURL, options: options)
                        if oldAttrs.type == .characterDevice || oldAttrs.type == .blockDevice {
                            return nil
                        }
                        return .deleted(path: rel)
                    }

                    // Device nodes (char/block) are treated as absent. A deletion for old-non-device/new-device is already emitted in pass 1; skip here to avoid duplicates.
                    let newAttrs = try await inspector.inspect(url: newURL, options: options)
                    if newAttrs.type == .characterDevice || newAttrs.type == .blockDevice {
                        return nil
                    }
                    return nil
                }
                inFlight += 1
                if inFlight >= concurrency {
                    if let d = try await group.next(), let dd = d { changes.append(dd) }
                    inFlight -= 1
                }
            }
            while let d = try await group.next() {
                if let dd = d { changes.append(dd) }
            }
        }

        return dedupeStable(changes).sorted(by: diffPathLessThan)
    }

    private func buildFileMap(for directory: URL) async throws -> [BinaryPath: NormalizedFileAttributes] {
        var map: [BinaryPath: NormalizedFileAttributes] = [:]

        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    URLResourceKey.isRegularFileKey,
                    URLResourceKey.isDirectoryKey,
                    URLResourceKey.isSymbolicLinkKey,
                    URLResourceKey.fileSizeKey,
                    URLResourceKey.contentModificationDateKey,
                ],
                options: []
            )
        else {
            throw DifferError.cannotEnumerateDirectory(directory)
        }

        while let fileURL = enumerator.nextObject() as? URL {
            let relativePath = self.relativePath(of: fileURL, base: directory)
            var attrs = try await inspector.inspect(url: fileURL, options: options)
            // Preserve canonical relative path in attributes for potential downstream use
            attrs.path = relativePath
            map[relativePath] = attrs
        }

        return map
    }

    // MARK: - Helpers

    private func relativePath(of url: URL, base: URL) -> BinaryPath {
        // Standardize both URLs to handle macOS /private prefix
        let standardURL = url.standardizedFileURL
        let standardBase = base.standardizedFileURL

        // Get raw bytes from standardized filesystem representations
        let standardURLPath = BinaryPath(url: standardURL)
        let standardBasePath = BinaryPath(url: standardBase)

        // Try to compute relative path using standardized paths
        if let relative = standardURLPath.relativePath(from: standardBasePath) {
            return relative
        }

        // Fallback: try with original paths
        let urlPath = BinaryPath(url: url)
        let basePath = BinaryPath(url: base)

        if let relative = urlPath.relativePath(from: basePath) {
            return relative
        }

        // Last resort - shouldn't happen in normal usage
        return urlPath.lastPathComponent
    }

    private func makeNode(from type: FileNodeType) -> Diff.Modified.Node {
        switch type {
        case .regular: return .regular
        case .directory: return .directory
        case .symlink: return .symlink
        case .characterDevice, .blockDevice: return .device
        case .fifo: return .fifo
        case .socket: return .socket
        }
    }

    private func xattrsDict(from attrs: NormalizedFileAttributes) -> [String: Data]? {
        guard !attrs.xattrs.isEmpty else { return nil }
        var dict: [String: Data] = [:]
        for e in attrs.xattrs { dict[e.key] = e.value }
        return dict
    }

    private func makeAdded(from attrs: NormalizedFileAttributes, path: BinaryPath) -> Diff {
        let node = makeNode(from: attrs.type)
        let permissions = attrs.mode.map { FilePermissions(rawValue: $0) }
        let size = attrs.size
        let modificationTime: Date? = attrs.mtimeNS.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000.0) }
        let linkTarget = attrs.symlinkTarget
        let uid = attrs.uid
        let gid = attrs.gid
        let xattrs = xattrsDict(from: attrs)
        return .added(
            .init(
                path: path,
                node: node,
                permissions: permissions,
                size: size,
                modificationTime: modificationTime,
                linkTarget: linkTarget,
                uid: uid,
                gid: gid,
                xattrs: xattrs,
                devMajor: nil,
                devMinor: nil,
                nlink: nil
            )
        )
    }

    private func makeModified(kind: Diff.Modified.Kind, newAttrs: NormalizedFileAttributes, path: BinaryPath) -> Diff {
        let node = makeNode(from: newAttrs.type)
        let permissions = newAttrs.mode.map { FilePermissions(rawValue: $0) }
        let size = newAttrs.size
        let modificationTime: Date? = newAttrs.mtimeNS.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000.0) }
        let linkTarget = newAttrs.symlinkTarget
        return .modified(
            .init(
                path: path,
                kind: kind,
                node: node,
                permissions: permissions,
                size: size,
                modificationTime: modificationTime,
                linkTarget: linkTarget,
                uid: newAttrs.uid,
                gid: newAttrs.gid,
                xattrs: xattrsDict(from: newAttrs),
                devMajor: nil,
                devMinor: nil,
                nlink: nil
            )
        )
    }

    private func diffPathLessThan(_ lhs: Diff, _ rhs: Diff) -> Bool {
        let lp: BinaryPath = {
            switch lhs {
            case .added(let a): return a.path
            case .modified(let m): return m.path
            case .deleted(let p): return p
            }
        }()
        let rp: BinaryPath = {
            switch rhs {
            case .added(let a): return a.path
            case .modified(let m): return m.path
            case .deleted(let p): return p
            }
        }()
        return lp < rp
    }
}

// Centralized factory for a default DirectoryDiffer with consistent normalization
extension DirectoryDiffer {
    public static func makeDefault(
        hasher: any ContentHasher,
        options: InspectorOptions = InspectorOptions()
    ) -> DirectoryDiffer {
        DirectoryDiffer(
            inspector: DefaultFileAttributeInspector(options: options),
            fileDiffer: FileDiffer(
                contentDiffer: FileContentDiffer(hasher: hasher),
                metadataDiffer: FileMetadataDiffer(options: options)
            ),
            options: options
        )
    }
}
