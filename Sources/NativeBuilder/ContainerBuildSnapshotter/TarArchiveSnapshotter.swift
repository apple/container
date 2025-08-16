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

import ContainerBuildIR
import ContainerClient
import ContainerizationOCI
import Foundation

/// Configuration for TarArchiveSnapshotter.
public struct TarArchiveSnapshotterConfiguration: Sendable {
    public let workingRoot: URL
    public let differ: TarArchiveDiffer
    public let limits: ResourceLimits
    public let normalizeTimestamps: Bool

    public init(
        workingRoot: URL,
        differ: TarArchiveDiffer,
        limits: ResourceLimits = ResourceLimits(),
        normalizeTimestamps: Bool = true
    ) {
        self.workingRoot = workingRoot
        self.differ = differ
        self.limits = limits
        self.normalizeTimestamps = normalizeTimestamps
    }
}

// MARK: - Errors

enum TarArchiveSnapshotterError: LocalizedError {
    case invalidSnapshotState(String)
    case missingMountpoint(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidSnapshotState(let details):
            return "Invalid snapshot state: \(details)"
        case .missingMountpoint(let id):
            return "Snapshot \(id) missing mountpoint"
        }
    }
}

// MARK: - Snapshotter

/// Tar-archive based snapshotter that conforms to Snapshotter and can optionally provide extended commit outcomes.
public final actor TarArchiveSnapshotter: Snapshotter {
    public typealias DiffFormat = TarArchiveDiffer.DiffFormat

    private let cfg: TarArchiveSnapshotterConfiguration
    // Cache of materialized base mountpoints keyed by layer digest string (e.g., "sha256:...").
    private var materializedBases: [String: URL] = [:]

    public init(configuration: TarArchiveSnapshotterConfiguration) {
        self.cfg = configuration
    }

    // Prepare ensures a mountpoint exists for the snapshot in prepared state.
    public func prepare(_ snapshot: Snapshot) async throws -> Snapshot {
        guard case .prepared(let mount) = snapshot.state else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("expected .prepared, got \(snapshot.state)")
        }
        try ensureDirectory(at: mount)

        // Materialize lineage base (if any) so we can diff against it during commit.
        if let parent = snapshot.parent {
            switch parent.state {
            case .prepared(let baseMount):
                // Already prepared; remember for commit
                materializedBases[parent.state.layerDigest ?? parent.digest.stringValue] = baseMount
            case .committed:
                // Try to materialize committed parent so commit can diff against a prepared base.
                if let mat = try? await materializeCommitted(parent) {
                    let key = parent.state.layerDigest ?? parent.digest.stringValue
                    materializedBases[key] = mat
                }
            default:
                break
            }
        }

        return snapshot
    }

    // Commit produces a tar layer for the snapshot and returns a committed Snapshot with layer metadata.
    public func commit(_ snapshot: Snapshot) async throws -> Snapshot {
        guard case .prepared = snapshot.state else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("commit requires .prepared")
        }

        // Resolve base from parent snapshot (if available)
        var baseForDiffer: Snapshot? = nil
        if let parent = snapshot.parent {
            switch parent.state {
            case .prepared(let baseMount):
                // Parent already has a mountpoint; use directly
                materializedBases[parent.state.layerDigest ?? parent.digest.stringValue] = baseMount
                baseForDiffer = parent
            case .committed:
                // Use pre-materialized mount from prepare or materialize now
                let key = parent.state.layerDigest ?? parent.digest.stringValue
                if let cachedMount = materializedBases[key] {
                    let preparedBase = Snapshot(
                        id: parent.id,
                        digest: parent.digest,
                        size: parent.size,
                        parent: parent.parent,
                        createdAt: parent.createdAt,
                        state: .prepared(mountpoint: cachedMount)
                    )
                    baseForDiffer = preparedBase
                } else if let mat = try? await materializeCommitted(parent) {
                    materializedBases[key] = mat
                    let preparedBase = Snapshot(
                        id: parent.id,
                        digest: parent.digest,
                        size: parent.size,
                        parent: parent.parent,
                        createdAt: parent.createdAt,
                        state: .prepared(mountpoint: mat)
                    )
                    baseForDiffer = preparedBase
                } else {
                    baseForDiffer = nil
                }
            default:
                baseForDiffer = nil
            }
        }

        // Compute diff and stream tar via differ; descriptor includes digest/size/mediaType.
        let descriptor = try await cfg.differ.diff(
            base: baseForDiffer,
            target: snapshot,
            format: .gzip,
            metadata: [:]
        )

        // Parse digest and construct committed snapshot with layer metadata in state
        let parsedDigest = try Digest(parsing: descriptor.digest)

        // Compute canonical Merkle-based DiffKey (bind to parent digest and mount if available)
        guard let targetMount = snapshot.state.mountpoint else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("commit requires prepared mountpoint")
        }

        // First compute the diffs using the differ's directory differ
        let changes = try await cfg.differ.directoryDiffer.diff(
            base: baseForDiffer?.state.mountpoint,
            target: targetMount
        )

        // Then compute the key from those diffs
        let key = try await DiffKey.computeFromDiffs(
            changes,
            baseDigest: snapshot.parent?.digest,
            baseMount: baseForDiffer?.state.mountpoint,
            targetMount: targetMount,
            hasher: SHA256ContentHasher()
        )

        let committed = Snapshot(
            id: snapshot.id,
            digest: parsedDigest,
            size: descriptor.size,
            parent: snapshot.parent,
            createdAt: snapshot.createdAt,
            state: .committed(
                layerDigest: descriptor.digest,
                layerSize: descriptor.size,
                layerMediaType: descriptor.mediaType,
                diffID: descriptor.annotations?["com.apple.container-build.layer.diff_id"],
                diffKey: key
            )
        )

        return committed
    }

    // Remove cleans up the working directory for prepared snapshots.
    public func remove(_ snapshot: Snapshot) async throws {
        guard case .prepared(let mount) = snapshot.state else {
            // Nothing to remove for non-prepared snapshots
            return
        }
        try? FileManager.default.removeItem(at: mount)
    }

    // MARK: - Extended API

    /// Commit with explicit base snapshot for better delta compression.
    /// The base is used for diffing if it's in a prepared state.
    public func commit(_ snapshot: Snapshot, base: Snapshot?) async throws -> Snapshot {
        guard case .prepared = snapshot.state else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("commit requires .prepared")
        }

        // Use base for diffing only if it is already in prepared state (has a mountpoint).
        // If not prepared (e.g., committed only), fall back to scratch for differ
        // while still incorporating base digest into the diffKey for reuse semantics.
        let baseForDiffer: Snapshot?
        if let b = base, case .prepared = b.state {
            baseForDiffer = b
        } else {
            baseForDiffer = nil
        }

        // Compute diff and stream tar via differ; descriptor includes digest/size/mediaType.
        let descriptor = try await cfg.differ.diff(
            base: baseForDiffer,
            target: snapshot,
            format: .gzip,
            metadata: [:]
        )

        // Parse digest and construct committed snapshot with layer metadata in state
        let parsedDigest = try Digest(parsing: descriptor.digest)

        // Compute canonical Merkle-based DiffKey, binding to provided base's digest (even if not prepared)
        guard let targetMount = snapshot.state.mountpoint else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("commit requires prepared mountpoint")
        }
        let baseMount = baseForDiffer?.state.mountpoint

        // First compute the diffs using the differ's directory differ
        let changes = try await cfg.differ.directoryDiffer.diff(
            base: baseMount,
            target: targetMount
        )

        // Then compute the key from those diffs
        let key = try await DiffKey.computeFromDiffs(
            changes,
            baseDigest: base?.digest,
            baseMount: baseMount,
            targetMount: targetMount,
            hasher: SHA256ContentHasher()
        )

        let committed = Snapshot(
            id: snapshot.id,
            digest: parsedDigest,
            size: descriptor.size,
            parent: snapshot.parent,
            createdAt: snapshot.createdAt,
            state: .committed(
                layerDigest: descriptor.digest,
                layerSize: descriptor.size,
                layerMediaType: descriptor.mediaType,
                diffID: descriptor.annotations?["com.apple.container-build.layer.diff_id"],
                diffKey: key
            )
        )

        return committed
    }

    // MARK: - Helpers

    private func ensureDirectory(at url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw TarArchiveSnapshotterError.invalidSnapshotState("mountpoint exists but is not a directory: \(url.path)")
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // Materialize a committed snapshot into a prepared mountpoint directory.
    // Ensures its parent (if any) is materialized first, then applies ONLY this snapshot's layer.
    // This aligns with the "apply parent first, then self" invariant and allows early exits.
    private func materializeCommitted(_ node: Snapshot) async throws -> URL {
        // Verify committed state
        guard case .committed = node.state else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("parent is not committed")
        }
        guard let currentLayerDigest = node.state.layerDigest else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("committed parent missing layer digest")
        }

        // If we've already materialized this layer during this run, return cached directory
        if let cached = materializedBases[currentLayerDigest] {
            return cached
        }

        // Destination path derived from the committed snapshot's layer digest
        let baseRoot = cfg.workingRoot.appendingPathComponent("materialized", isDirectory: true)
        let folderName = currentLayerDigest.replacingOccurrences(of: ":", with: "_")
        let dest = baseRoot.appendingPathComponent(folderName, isDirectory: true)

        // Reuse if already materialized on disk
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
            materializedBases[currentLayerDigest] = dest
            return dest
        }

        // Ensure parent directory exists
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)

        // If there's a parent, ensure it is materialized first, then clone/copy it as our starting point.
        if let p = node.parent {
            guard case .committed = p.state else {
                throw TarArchiveSnapshotterError.invalidSnapshotState("ancestor not committed")
            }
            guard p.state.layerDigest != nil else {
                throw TarArchiveSnapshotterError.invalidSnapshotState("ancestor missing layer digest")
            }

            let parentDest = try await materializeCommitted(p)

            // Ensure we start from a clean destination, then copy the parent's tree.
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: parentDest, to: dest)
        } else {
            // No parent: start from empty root directory
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        }

        // Fetch only THIS snapshot's layer blob and apply on top of prepared base
        let store = cfg.differ.contentStore
        guard let content = try await store.get(digest: currentLayerDigest) else {
            throw TarArchiveSnapshotterError.invalidSnapshotState("missing content for layer \(currentLayerDigest)")
        }
        let bytes = try content.data()

        // Heuristic: use declared media type if present, else default to gzip (our differ default)
        let mediaType = node.state.layerMediaType ?? "application/vnd.oci.image.layer.v1.tar+gzip"

        // Persist to a temp file for ArchiveReader
        let suffix = mediaType.contains("+gzip") ? ".tar.gz" : ".tar"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("layer-\(UUID().uuidString)\(suffix)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try bytes.write(to: tmp)

        // Apply only this layer on top of the prepared base
        try cfg.differ.applyChain(to: dest, layers: [(url: tmp, mediaType: mediaType)])

        // Cache and return
        materializedBases[currentLayerDigest] = dest
        return dest
    }
}
