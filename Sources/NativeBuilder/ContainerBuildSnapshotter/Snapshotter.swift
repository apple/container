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
import Foundation

/// Manages filesystem snapshots during build execution.
///
/// The snapshotter is responsible for creating and managing filesystem
/// snapshots that represent the state at different points in the build.
public protocol Snapshotter: Sendable {
    /// Create a new snapshot from the current state.
    ///
    /// - Parameters:
    ///   - parent: The parent snapshot to base this on
    ///   - changes: The filesystem changes to apply
    /// - Returns: The new snapshot
    func createSnapshot(
        from parent: Snapshot?,
        applying changes: FilesystemChanges
    ) async throws -> Snapshot

    /// Prepare a snapshot for use (e.g., mount it).
    ///
    /// - Parameter snapshot: The snapshot to prepare
    /// - Returns: A handle to the prepared snapshot
    func prepare(_ snapshot: Snapshot) async throws -> SnapshotHandle

    /// Commit a snapshot, making it permanent.
    ///
    /// - Parameter snapshot: The snapshot to commit
    /// - Returns: The committed snapshot with final digest
    func commit(_ snapshot: Snapshot) async throws -> Snapshot

    /// Remove a snapshot.
    ///
    /// - Parameter snapshot: The snapshot to remove
    func remove(_ snapshot: Snapshot) async throws

    /// Get the diff between two snapshots.
    ///
    /// - Parameters:
    ///   - from: The base snapshot
    ///   - to: The target snapshot
    /// - Returns: The filesystem changes between snapshots
    func diff(from: Snapshot?, to: Snapshot) async throws -> FilesystemChanges
}

/// A handle to a prepared snapshot.
public struct SnapshotHandle: Sendable {
    /// The snapshot being handled.
    public let snapshot: Snapshot

    /// The mount point or working directory for the snapshot.
    public let path: String

    /// Cleanup function to call when done.
    private let cleanup: @Sendable () async -> Void

    public init(
        snapshot: Snapshot,
        path: String,
        cleanup: @escaping @Sendable () async -> Void
    ) {
        self.snapshot = snapshot
        self.path = path
        self.cleanup = cleanup
    }

    /// Clean up the prepared snapshot.
    public func close() async {
        await cleanup()
    }
}

/// A memory-based snapshotter for development/testing.
public actor MemorySnapshotter: Snapshotter {
    private var snapshots: [UUID: SnapshotData] = [:]
    private var nextId = 0

    private struct SnapshotData {
        let snapshot: Snapshot
        let changes: FilesystemChanges
        var committed: Bool
    }

    public init() {}

    public func createSnapshot(
        from parent: Snapshot?,
        applying changes: FilesystemChanges
    ) async throws -> Snapshot {
        nextId += 1
        let id = UUID()

        // Create a fake 32-byte digest for sha256
        var digestBytes = Data(count: 32)
        digestBytes.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                memset(baseAddress, Int32(nextId % 256), 32)
            }
        }
        let digest = try Digest(algorithm: .sha256, bytes: digestBytes)

        let snapshot = Snapshot(
            id: id,
            digest: digest,
            size: abs(changes.sizeChange),
            parent: parent?.id
        )

        snapshots[id] = SnapshotData(
            snapshot: snapshot,
            changes: changes,
            committed: false
        )

        return snapshot
    }

    public func prepare(_ snapshot: Snapshot) async throws -> SnapshotHandle {
        guard snapshots[snapshot.id] != nil else {
            throw SnapshotError.notFound(snapshot.id)
        }

        // For memory snapshotter, we just return a temp directory
        let path = "/tmp/snapshot-\(snapshot.id)"

        return SnapshotHandle(
            snapshot: snapshot,
            path: path,
            cleanup: { [weak self] in
                // In a real implementation, this would unmount/cleanup
                _ = self
            }
        )
    }

    public func commit(_ snapshot: Snapshot) async throws -> Snapshot {
        guard var data = snapshots[snapshot.id] else {
            throw SnapshotError.notFound(snapshot.id)
        }

        // Mark as committed
        data.committed = true
        snapshots[snapshot.id] = data

        return snapshot
    }

    public func remove(_ snapshot: Snapshot) async throws {
        snapshots.removeValue(forKey: snapshot.id)
    }

    public func diff(from base: Snapshot?, to target: Snapshot) async throws -> FilesystemChanges {
        guard let targetData = snapshots[target.id] else {
            throw SnapshotError.notFound(target.id)
        }

        // For simplicity, just return the target's changes
        return targetData.changes
    }
}

/// Errors that can occur during snapshot operations.
public enum SnapshotError: LocalizedError {
    case notFound(UUID)
    case invalidParent(UUID)
    case commitFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Snapshot not found: \(id)"
        case .invalidParent(let id):
            return "Invalid parent snapshot: \(id)"
        case .commitFailed(let error):
            return "Failed to commit snapshot: \(error.localizedDescription)"
        }
    }
}
