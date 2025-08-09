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

            return additions.sorted(by: diffPathLessThan)
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
                let oldURL = base.appendingPathComponent(rel)
                group.addTask {
                    let newAttrs = try await inspector.inspect(url: newURL, options: options)
                    guard FileManager.default.fileExists(atPath: oldURL.path) else {
                        return makeAdded(from: newAttrs, path: rel)
                    }
                    let oldAttrs = try await inspector.inspect(url: oldURL, options: options)
                    let result = try fileDiffer.diff(
                        oldAttrs: oldAttrs,
                        newAttrs: newAttrs,
                        oldURL: oldURL,
                        newURL: newURL,
                        options: options
                    )
                    if let kind = Diff.Modified.Kind(result) {
                        return makeModified(kind: kind, newAttrs: newAttrs, path: rel)
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
                let newURL = target.appendingPathComponent(rel)
                group.addTask {
                    if !FileManager.default.fileExists(atPath: newURL.path) {
                        return .deleted(path: rel)
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

        return changes.sorted(by: diffPathLessThan)
    }

    private func buildFileMap(for directory: URL) async throws -> [String: NormalizedFileAttributes] {
        var map: [String: NormalizedFileAttributes] = [:]

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
            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            var attrs = try await inspector.inspect(url: fileURL, options: options)
            // Preserve canonical relative path in attributes for potential downstream use
            attrs.path = relativePath
            map[relativePath] = attrs
        }

        return map
    }

    // MARK: - Helpers

    private func relativePath(of url: URL, base: URL) -> String {
        // Get standardized paths
        let urlPath = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path

        // Ensure base path ends with a separator
        let basePathWithSeparator = basePath.hasSuffix("/") ? basePath : basePath + "/"

        // Check if url is under base
        if urlPath.hasPrefix(basePathWithSeparator) {
            return String(urlPath.dropFirst(basePathWithSeparator.count))
        }

        // If not a direct prefix match, might be due to symlinks
        // Try resolving symlinks for both paths
        if let resolvedURL = try? url.resolvingSymlinksInPath(),
            let resolvedBase = try? base.resolvingSymlinksInPath()
        {
            let resolvedURLPath = resolvedURL.path
            let resolvedBasePath = resolvedBase.path
            let resolvedBaseWithSeparator = resolvedBasePath.hasSuffix("/") ? resolvedBasePath : resolvedBasePath + "/"

            if resolvedURLPath.hasPrefix(resolvedBaseWithSeparator) {
                // Use the original URL path to compute relative path
                // to preserve symlink names in the result
                if urlPath.hasPrefix(basePathWithSeparator) {
                    return String(urlPath.dropFirst(basePathWithSeparator.count))
                }
                // Fall back to using resolved path
                return String(resolvedURLPath.dropFirst(resolvedBaseWithSeparator.count))
            }
        }

        // Last resort - shouldn't happen in normal usage
        return url.lastPathComponent
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

    private func makeAdded(from attrs: NormalizedFileAttributes, path: String) -> Diff {
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

    private func makeModified(kind: Diff.Modified.Kind, newAttrs: NormalizedFileAttributes, path: String) -> Diff {
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
        let lp: String = {
            switch lhs {
            case .added(let a): return a.path
            case .modified(let m): return m.path
            case .deleted(let p): return p
            }
        }()
        let rp: String = {
            switch rhs {
            case .added(let a): return a.path
            case .modified(let m): return m.path
            case .deleted(let p): return p
            }
        }()
        return lp < rp
    }
}
