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

import Compression
import ContainerBuildIR
import ContainerClient
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import System

/// A concrete implementation of Differ that creates tar archives of filesystem changes
///
/// This implementation:
/// - Computes filesystem deltas between snapshots
/// - Creates tar archives following OCI layer specifications
/// - Applies compression (gzip, zstd, estargz)
/// - Stores results in a content store
public final class TarArchiveDiffer: Differ {
    public let contentStore: any ContentStore

    private let inspector: any FileAttributeInspector
    private let hasher: any ContentHasher
    let inspectorOptions: InspectorOptions
    let directoryDiffer: DirectoryDiffer

    /// Compression format for diff archives, following BuildKit conventions
    public enum DiffFormat: String, Codable, Sendable, CaseIterable {
        case uncompressed = "uncompressed"
        case gzip = "gzip"
        case zstd = "zstd"
        case estargz = "estargz"

        /// The OCI media type for this compression format
        public var mediaType: String {
            switch self {
            case .uncompressed:
                return "application/vnd.oci.image.layer.v1.tar"
            case .gzip:
                return "application/vnd.oci.image.layer.v1.tar+gzip"
            case .zstd:
                return "application/vnd.oci.image.layer.v1.tar+zstd"
            case .estargz:
                return "application/vnd.oci.image.layer.v1.tar+gzip"
            }
        }

        /// File extension for this format
        /// This will only go into the descriptor annotations
        /// The filenames will be digests
        public var fileExtension: String {
            switch self {
            case .uncompressed:
                return ".tar"
            case .gzip:
                return ".tar.gz"
            case .zstd:
                return ".tar.zst"
            case .estargz:
                return ".tar.gz"
            }
        }

        /// Whether this format uses compression
        public var isCompressed: Bool {
            self != .uncompressed
        }
    }

    public init(contentStore: any ContentStore) {
        self.contentStore = contentStore
        self.inspectorOptions = InspectorOptions()
        self.inspector = DefaultFileAttributeInspector(options: self.inspectorOptions)
        self.hasher = SHA256ContentHasher()
        self.directoryDiffer = DirectoryDiffer.makeDefault(
            hasher: self.hasher,
            options: self.inspectorOptions
        )
    }

    public init(
        contentStore: any ContentStore,
        inspector: any FileAttributeInspector,
        hasher: any ContentHasher,
        inspectorOptions: InspectorOptions = InspectorOptions()
    ) {
        self.contentStore = contentStore
        self.inspector = inspector
        self.hasher = hasher
        self.inspectorOptions = inspectorOptions
        self.directoryDiffer = DirectoryDiffer.makeDefault(
            hasher: self.hasher,
            options: self.inspectorOptions
        )
    }

    // Differ protocol conformance
    public func diff(
        base: Snapshot?,
        target: Snapshot
    ) async throws -> Descriptor {
        try await diff(
            base: base,
            target: target,
            format: .gzip,
            metadata: [:]
        )
    }

    public func diff(
        base: Snapshot?,
        target: Snapshot,
        format: DiffFormat,
        metadata: [String: String]
    ) async throws -> Descriptor {
        // Validate snapshots are in the correct state
        guard case .prepared(let targetMount) = target.state else {
            throw DifferError.snapshotNotPrepared(target.id)
        }

        let baseMountpoint: URL?
        if let base = base {
            guard case .prepared(let baseMount) = base.state else {
                throw DifferError.snapshotNotPrepared(base.id)
            }
            baseMountpoint = baseMount
        } else {
            baseMountpoint = nil
        }

        // Compute the filesystem changes
        let changes = try await directoryDiffer.diff(base: baseMountpoint, target: targetMount)

        // Stage inputs for archiving (no intermediate tar data)
        let (stagingRoot, placeholderMap) = try await stageTarInputs(
            changes,
            sourceDirectory: targetMount
        )
        // Ensure staging directory is always cleaned up
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        // Stream directly into content store via ingest session
        let (sessionId, ingestDir) = try await contentStore.newIngestSession()
        let destination = ingestDir.appendingPathComponent("layer\(format.fileExtension)")

        var fileSize: Int64 = 0
        var ingestedDigests: [String] = []
        do {
            // Write tar stream directly with compression filter enabled
            try writeTarArchive(
                stagingRoot,
                placeholderMap: placeholderMap,
                format: format,
                destination: destination
            )

            // Determine size from file system (avoid buffering)
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            if let sz = (attrs[.size] as? NSNumber)?.int64Value {
                fileSize = sz
            }

            // Complete ingest session to register content and get digest(s)
            ingestedDigests = try await contentStore.completeIngestSession(sessionId)
        } catch {
            // Ensure ingest session is canceled if anything fails
            try? await contentStore.cancelIngestSession(sessionId)
            throw error
        }

        guard let digestString = ingestedDigests.first else {
            throw DifferError.compressionFailed("content-store-ingest")  // reuse error type for missing digest
        }

        // Build descriptor with metadata
        var annotations = metadata
        annotations["com.apple.container-build.diff.format"] = format.rawValue
        annotations["com.apple.container-build.diff.created"] = ISO8601DateFormatter().string(from: Date())

        if let base = base {
            annotations["com.apple.container-build.diff.base"] = base.digest.stringValue
        } else {
            annotations["com.apple.container-build.diff.base"] = "scratch"
        }
        annotations["com.apple.container-build.diff.target"] = target.digest.stringValue

        return Descriptor(
            mediaType: format.mediaType,
            digest: digestString,
            size: fileSize,
            urls: nil,
            annotations: annotations.isEmpty ? nil : annotations,
            platform: nil
        )
    }

    public func apply(
        descriptor: Descriptor,
        to base: Snapshot?
    ) async throws -> Snapshot {
        // TODO: Implement apply operation
        // This would:
        // 1. Fetch the diff from content store using descriptor.digest
        // 2. Decompress based on descriptor.mediaType
        // 3. Extract tar archive to a working directory
        // 4. Apply changes on top of base snapshot
        // 5. Return new snapshot
        throw DifferError.notImplemented("apply")
    }
}

extension TarArchiveDiffer {
    // Map DiffFormat to ArchiveWriterConfiguration filter
    func archiveFilter(for format: DiffFormat) throws -> ArchiveWriterConfiguration {
        switch format {
        case .uncompressed:
            return ArchiveWriterConfiguration(format: .paxRestricted, filter: .none)
        case .gzip:
            return ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip)
        case .zstd, .estargz:
            throw DifferError.notImplemented("zstd or estargz")
        }
    }

    // Stage inputs needed by Archiver.compress without writing an intermediate tar file.
    // Returns the staging root URL (callers must clean it up) and a map from placeholder URLs to entry info.
    func stageTarInputs(
        _ changes: [Diff],
        sourceDirectory: URL
    ) async throws -> (stagingRoot: URL, placeholderMap: [URL: Archiver.ArchiveEntryInfo]) {
        // Create a temporary directory for staging
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("differ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Prepare entries for archiving
        var entriesToArchive: [Archiver.ArchiveEntryInfo] = []

        // Stage files for the tar archive
        for change in changes {
            switch change {
            case .added(let a):
                let path = a.path
                // For filesystem operations, we need a valid UTF-8 path
                guard let pathString = path.stringValue else {
                    // Skip files with non-UTF8 paths that can't be represented on this system
                    continue
                }
                let sourceFile = sourceDirectory.appendingPathComponent(pathString)
                if FileManager.default.fileExists(atPath: sourceFile.path) {
                    // Prefer Diff payload for uid/gid/permissions overrides
                    entriesToArchive.append(
                        Archiver.ArchiveEntryInfo(
                            pathOnHost: sourceFile,
                            pathInArchive: URL(fileURLWithPath: pathString),
                            owner: a.uid,
                            group: a.gid,
                            permissions: a.permissions?.rawValue
                        )
                    )

                    if inspectorOptions.enableXAttrsCapture {
                        // Prefer xattrs from Diff payload; fall back to inspector if absent
                        let payloadXAttrs: [XAttrEntry]? = {
                            guard let dict = a.xattrs, !dict.isEmpty else { return nil }
                            let keys = Array(dict.keys).sorted()
                            return keys.map { key in XAttrEntry(key: key, value: dict[key]!) }
                        }()

                        let entries: [XAttrEntry]
                        if let payload = payloadXAttrs {
                            entries = payload
                        } else if let fromInspector = try? await inspector.listXAttrs(url: sourceFile, options: inspectorOptions),
                            !fromInspector.isEmpty
                        {
                            entries = fromInspector
                        } else {
                            entries = []
                        }

                        if !entries.isEmpty {
                            let blob = XAttrCodec.encode(entries)
                            let sidecarRel = ".container/xattrs/\(pathString).bin"
                            let sidecarHost = tempDir.appendingPathComponent(sidecarRel)

                            try FileManager.default.createDirectory(
                                at: sidecarHost.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try blob.write(to: sidecarHost)

                            entriesToArchive.append(
                                Archiver.ArchiveEntryInfo(
                                    pathOnHost: sidecarHost,
                                    pathInArchive: URL(fileURLWithPath: sidecarRel)
                                )
                            )
                        }
                    }
                }

            case .modified(let m):
                let path = m.path
                // For filesystem operations, we need a valid UTF-8 path
                guard let pathString = path.stringValue else {
                    // Skip files with non-UTF8 paths that can't be represented on this system
                    continue
                }
                let sourceFile = sourceDirectory.appendingPathComponent(pathString)
                if FileManager.default.fileExists(atPath: sourceFile.path) {
                    // Prefer Diff payload for uid/gid/permissions overrides
                    entriesToArchive.append(
                        Archiver.ArchiveEntryInfo(
                            pathOnHost: sourceFile,
                            pathInArchive: URL(fileURLWithPath: pathString),
                            owner: m.uid,
                            group: m.gid,
                            permissions: m.permissions?.rawValue
                        )
                    )

                    if inspectorOptions.enableXAttrsCapture {
                        // Prefer xattrs from Diff payload; fall back to inspector if absent
                        let payloadXAttrs: [XAttrEntry]? = {
                            guard let dict = m.xattrs, !dict.isEmpty else { return nil }
                            let keys = Array(dict.keys).sorted()
                            return keys.map { key in XAttrEntry(key: key, value: dict[key]!) }
                        }()

                        let entries: [XAttrEntry]
                        if let payload = payloadXAttrs {
                            entries = payload
                        } else if let fromInspector = try? await inspector.listXAttrs(url: sourceFile, options: inspectorOptions),
                            !fromInspector.isEmpty
                        {
                            entries = fromInspector
                        } else {
                            entries = []
                        }

                        if !entries.isEmpty {
                            let blob = XAttrCodec.encode(entries)
                            let sidecarRel = ".container/xattrs/\(pathString).bin"
                            let sidecarHost = tempDir.appendingPathComponent(sidecarRel)

                            try FileManager.default.createDirectory(
                                at: sidecarHost.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try blob.write(to: sidecarHost)

                            entriesToArchive.append(
                                Archiver.ArchiveEntryInfo(
                                    pathOnHost: sidecarHost,
                                    pathInArchive: URL(fileURLWithPath: sidecarRel)
                                )
                            )
                        }
                    }
                }

            case .deleted(let path):
                // Use BinaryPath operations to handle deletion correctly
                let lastComponent = path.lastPathComponent
                // Create whiteout filename by prepending ".wh." to the last component
                let whiteoutName = BinaryPath(string: ".wh." + lastComponent.requireString)
                let whiteoutDir = path.deletingLastPathComponent()
                let whiteoutPath = whiteoutDir.isEmpty ? whiteoutName : whiteoutDir.appending(whiteoutName)

                // For filesystem operations, we need a valid UTF-8 path
                guard let whiteoutPathString = whiteoutPath.stringValue else {
                    // Skip files with non-UTF8 paths that can't be represented on this system
                    continue
                }

                let whiteoutFile = tempDir.appendingPathComponent(whiteoutPathString)
                try FileManager.default.createDirectory(
                    at: whiteoutFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = FileManager.default.createFile(atPath: whiteoutFile.path, contents: Data(), attributes: nil)

                entriesToArchive.append(
                    Archiver.ArchiveEntryInfo(
                        pathOnHost: whiteoutFile,
                        pathInArchive: URL(fileURLWithPath: whiteoutPathString)
                    )
                )
            }
        }

        // Build a placeholder tree under tempDir so Archiver can enumerate exactly our intended entries.
        // We map each placeholder URL back to the actual entry to archive (which may point outside tempDir).
        var placeholderMap: [URL: Archiver.ArchiveEntryInfo] = [:]
        for entry in entriesToArchive {
            let relPath = entry.pathInArchive.relativePath
            let placeholder = tempDir.appendingPathComponent(relPath).standardizedFileURL

            // Ensure parent directories exist
            try FileManager.default.createDirectory(
                at: placeholder.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Create a directory placeholder when the source is a directory; otherwise create an empty file.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.pathOnHost.path, isDirectory: &isDir), isDir.boolValue {
                if !FileManager.default.fileExists(atPath: placeholder.path, isDirectory: &isDir) || !isDir.boolValue {
                    try? FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
                }
            } else {
                _ = FileManager.default.createFile(atPath: placeholder.path, contents: Data(), attributes: nil)
            }

            placeholderMap[placeholder] = entry
        }

        return (stagingRoot: tempDir, placeholderMap: placeholderMap)
    }

    // Write the tar archive by streaming entries into the destination with an appropriate compression filter.
    func writeTarArchive(
        _ stagingRoot: URL,
        placeholderMap: [URL: Archiver.ArchiveEntryInfo],
        format: DiffFormat,
        destination: URL
    ) throws {
        let writerConfig = try archiveFilter(for: format)

        try Archiver.compress(
            source: stagingRoot,
            destination: destination,
            writerConfiguration: writerConfig
        ) { url in
            placeholderMap[url.standardizedFileURL]
        }
    }

    // Apply a chain of OCI layers to a root filesystem directory in order (base -> top).
    // Each layer is provided as a tar file URL along with its media type to select decompression.
    // Whiteouts and opaque markers are handled per OCI/overlayfs conventions.
    func applyChain(to root: URL, layers: [(url: URL, mediaType: String?)]) throws {
        // Ensure root exists
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (layerURL, mediaType) in layers {
            try applyTarLayer(file: layerURL, mediaType: mediaType, to: root)
        }
    }

    // MARK: - Layer Application (OCI semantics)

    private func applyTarLayer(file: URL, mediaType: String?, to root: URL) throws {
        let needsGzip: Bool
        if let mt = mediaType {
            needsGzip = mt.contains("+gzip")
        } else {
            // Default to gzip for our generated layers
            needsGzip = true
        }

        let reader = try ArchiveReader(
            format: .paxRestricted,
            filter: needsGzip ? .gzip : .none,
            file: file
        )

        let fm = FileManager.default

        // Accumulate sidecar xattrs by path. These are collected for potential
        // application in the future but are NOT applied by this implementation.
        // They are decoded and stored to preserve determinism and leave room for
        // a subsequent setxattr implementation.
        var pendingXAttrs: [String: [XAttrEntry]] = [:]

        for (entry, data) in reader {
            guard var pathInArchive = entry.path, !pathInArchive.isEmpty else { continue }
            // Normalize paths: strip leading "./"
            if pathInArchive.hasPrefix("./") {
                pathInArchive.removeFirst(2)
            }
            // Security: reject absolute paths and path traversal
            if pathInArchive.hasPrefix("/") { continue }
            if pathInArchive.split(separator: "/").contains("..") { continue }

            let lastComponent = (pathInArchive as NSString).lastPathComponent

            // OCI whiteout: opaque directory
            if lastComponent == ".wh..wh..opq" {
                let dirRel = (pathInArchive as NSString).deletingLastPathComponent
                let dirURL = root.appendingPathComponent(dirRel)
                try clearDirectoryContents(dirURL)
                // Do not materialize the marker file
                continue
            }

            // OCI whiteout: remove entry
            if lastComponent.hasPrefix(".wh.") {
                let removedName = String(lastComponent.dropFirst(4))
                let dirRel = (pathInArchive as NSString).deletingLastPathComponent
                let targetRel: String
                if dirRel.isEmpty || dirRel == "." {
                    targetRel = removedName
                } else {
                    targetRel = "\(dirRel)/\(removedName)"
                }
                let targetURL = root.appendingPathComponent(targetRel)
                if fm.fileExists(atPath: targetURL.path) {
                    try fm.removeItem(at: targetURL)
                }
                continue
            }

            // Sidecar xattrs handling: ".container/xattrs/<path>.bin"
            if pathInArchive.hasPrefix(".container/xattrs/"), pathInArchive.hasSuffix(".bin") {
                let prefix = ".container/xattrs/"
                let trimmed = String(pathInArchive.dropFirst(prefix.count))
                let targetRel = String(trimmed.dropLast(".bin".count))
                let entries = XAttrCodec.decode(data)
                if !entries.isEmpty {
                    pendingXAttrs[targetRel, default: []].append(contentsOf: entries)
                }
                continue
            }

            let dstURL = root.appendingPathComponent(pathInArchive)

            switch entry.fileType {
            case .directory:
                // If a non-directory exists at path, replace it
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dstURL.path, isDirectory: &isDir), !isDir.boolValue {
                    try? fm.removeItem(at: dstURL)
                }
                try fm.createDirectory(
                    at: dstURL,
                    withIntermediateDirectories: true,
                    attributes: [
                        .posixPermissions: NSNumber(value: entry.permissions)
                    ]
                )
                // Apply times best-effort
                if let mtime = entry.modificationDate {
                    try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dstURL.path)
                }
                if let ctime = entry.creationDate {
                    try fm.setAttributes([.creationDate: ctime], ofItemAtPath: dstURL.path)
                }

            case .regular:
                // Replace any existing node
                if fm.fileExists(atPath: dstURL.path) {
                    try? fm.removeItem(at: dstURL)
                }
                try fm.createDirectory(
                    at: dstURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let ok = fm.createFile(
                    atPath: dstURL.path,
                    contents: data,
                    attributes: [
                        .posixPermissions: NSNumber(value: entry.permissions)
                    ]
                )
                if !ok {
                    throw POSIXError.fromErrno()
                }
                // Ensure data persisted (createFile already writes; calling write again not necessary)
                // Apply times
                if let mtime = entry.modificationDate {
                    try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dstURL.path)
                }
                if let ctime = entry.creationDate {
                    try fm.setAttributes([.creationDate: ctime], ofItemAtPath: dstURL.path)
                }

            case .symbolicLink:
                guard let target = entry.symlinkTarget else { continue }
                // Replace existing node (file/dir/link) before creating symlink
                if fm.fileExists(atPath: dstURL.path) {
                    try? fm.removeItem(at: dstURL)
                }
                try fm.createDirectory(
                    at: dstURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.createSymbolicLink(atPath: dstURL.path, withDestinationPath: target)

            case .blockSpecial, .characterSpecial, .socket:
                // Not supported on macOS in this context; skip safely
                continue

            default:
                continue
            }
        }

        // XAttr application is intentionally not implemented here.
        // We capture and decode sidecar xattrs but do not set them on files.
        // This avoids introducing platform-specific APIs in this layer.
        _ = pendingXAttrs  // Collected but intentionally not applied
    }

    // Remove all entries inside a directory (if it exists), but keep the directory itself.
    private func clearDirectoryContents(_ directory: URL) throws {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
            let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            for item in contents {
                try? fm.removeItem(at: item)
            }
        }
    }

}

// MARK: - Error Types

enum DifferError: LocalizedError {
    case snapshotNotPrepared(UUID)
    case cannotEnumerateDirectory(URL)
    case compressionFailed(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .snapshotNotPrepared(let id):
            return "Snapshot \(id) is not in prepared state"
        case .cannotEnumerateDirectory(let url):
            return "Cannot enumerate directory at \(url.path)"
        case .compressionFailed(let format):
            return "Failed to compress data using \(format)"
        case .notImplemented(let feature):
            return "\(feature) is not yet implemented"
        }
    }
}
