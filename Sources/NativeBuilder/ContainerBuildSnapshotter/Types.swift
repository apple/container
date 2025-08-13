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

/// A filesystem snapshot representing state at a point in the build.
public final class Snapshot: Sendable, Codable {
    /// Unique identifier for this snapshot.
    public let id: UUID

    /// The digest of the snapshot content.
    public let digest: Digest

    /// Size of the snapshot in bytes.
    public let size: Int64

    /// Parent snapshot (if any). Must be in committed state to serve as base.
    public let parent: Snapshot?

    /// Timestamp when the snapshot was created.
    public let createdAt: Date

    /// The current state of the snapshot.
    public let state: SnapshotState

    /// Represents the lifecycle state of a snapshot.
    ///
    /// A snapshot transitions through different states during its lifecycle:
    /// - `prepared`: The snapshot is ready for operations to be performed on it.
    /// - `inProgress`: The snapshot is currently being modified by an operation.
    /// - `committed`: The snapshot has been finalized and is immutable.
    public enum SnapshotState: Sendable, Codable, Equatable {
        /// The snapshot is ready for operations to be performed on it.
        /// This is the initial state after a snapshot is created or prepared.
        /// - Parameter mountpoint: The URL where the snapshot filesystem is mounted and accessible
        case prepared(mountpoint: URL)

        /// The snapshot is currently being modified by an operation.
        /// - Parameter operationId: The UUID identifying the specific operation modifying the snapshot.
        case inProgress(operationId: UUID)

        /// The snapshot has been finalized and is immutable.
        /// No further modifications can be made to a committed snapshot.
        /// - Parameters:
        ///   - layerDigest: Optional digest of the tar layer produced (for tar-based snapshotters)
        ///   - layerSize: Optional size of the tar layer in bytes
        ///   - layerMediaType: Optional media type of the layer (e.g., "application/vnd.oci.image.layer.v1.tar+gzip")
        ///   - diffKey: Optional key for layer deduplication in cache
        case committed(layerDigest: String? = nil, layerSize: Int64? = nil, layerMediaType: String? = nil, diffKey: DiffKey? = nil)

        // MARK: - Helper Properties

        /// Returns true if the snapshot is in the prepared state.
        public var isPrepared: Bool {
            if case .prepared = self {
                return true
            }
            return false
        }

        /// Returns the mountpoint URL if the snapshot is prepared, nil otherwise.
        public var mountpoint: URL? {
            if case .prepared(let mountpoint) = self {
                return mountpoint
            }
            return nil
        }

        /// Returns true if the snapshot is in the inProgress state.
        public var isInProgress: Bool {
            if case .inProgress = self {
                return true
            }
            return false
        }

        /// Returns true if the snapshot is in the committed state.
        public var isCommitted: Bool {
            if case .committed = self {
                return true
            }
            return false
        }

        /// Returns the layer digest if the snapshot is committed with layer info, nil otherwise.
        public var layerDigest: String? {
            if case .committed(let digest, _, _, _) = self {
                return digest
            }
            return nil
        }

        /// Returns the layer size if the snapshot is committed with layer info, nil otherwise.
        public var layerSize: Int64? {
            if case .committed(_, let size, _, _) = self {
                return size
            }
            return nil
        }

        /// Returns the layer media type if the snapshot is committed with layer info, nil otherwise.
        public var layerMediaType: String? {
            if case .committed(_, _, let mediaType, _) = self {
                return mediaType
            }
            return nil
        }

        /// Returns the diff key if the snapshot is committed with layer info, nil otherwise.
        public var diffKey: DiffKey? {
            if case .committed(_, _, _, let key) = self {
                return key
            }
            return nil
        }

        /// Returns the operation ID if the snapshot is in progress, nil otherwise.
        public var operationID: UUID? {
            if case .inProgress(operationId: let id) = self {
                return id
            }
            return nil
        }

        // MARK: - Semantic Helper Properties

        /// Can this snapshot be modified?
        /// Returns true only if the snapshot is in the prepared state.
        public var canExecute: Bool {
            if case .prepared = self {
                return true
            }
            return false
        }

        /// Is this snapshot finalized?
        /// Returns true only if the snapshot is in the committed state.
        public var isFinalized: Bool {
            if case .committed = self {
                return true
            }
            return false
        }

        /// Is this snapshot locked for modification?
        /// Returns true if the snapshot is currently being modified by an operation.
        public var isLocked: Bool {
            if case .inProgress = self {
                return true
            }
            return false
        }
    }

    public init(
        id: UUID = UUID(),
        digest: Digest,
        size: Int64,
        parent: Snapshot? = nil,
        createdAt: Date = Date(),
        state: SnapshotState
    ) {
        self.id = id
        self.digest = digest
        self.size = size
        self.parent = parent
        self.createdAt = createdAt
        self.state = state
    }
}

/// Resource limits used by the snapshotter to bound memory/IO.
public struct ResourceLimits: Sendable {
    public var maxInFlightBytes: Int64

    public init(maxInFlightBytes: Int64 = 64 * 1024 * 1024) {
        self.maxInFlightBytes = maxInFlightBytes
    }
}
