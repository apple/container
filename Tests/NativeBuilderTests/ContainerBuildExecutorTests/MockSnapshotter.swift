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
import ContainerBuildSnapshotter
import Foundation

/// Mock snapshotter for testing
public actor MockSnapshotter: Snapshotter {
    private var snapshots: [UUID: Snapshot] = [:]
    private var mounts: [UUID: URL] = [:]

    public init() {}

    public func create(parent: Snapshot?) async throws -> Snapshot {
        let id = UUID()
        let digest = try Digest(algorithm: .sha256, bytes: Data(count: 32))
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshot = Snapshot(
            id: id,
            digest: digest,
            size: 0,
            parent: parent,
            state: .prepared(mountpoint: mountPoint)
        )
        snapshots[id] = snapshot
        return snapshot
    }

    public func prepare(_ snapshot: Snapshot) async throws -> Snapshot {
        // Mock implementation - just return the snapshot as prepared
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prepared = Snapshot(
            id: snapshot.id,
            digest: snapshot.digest,
            size: snapshot.size,
            parent: snapshot.parent,
            state: .prepared(mountpoint: mountPoint)
        )
        snapshots[snapshot.id] = prepared
        return prepared
    }

    public func commit(_ snapshot: Snapshot) async throws -> Snapshot {
        let committedDigest = try Digest(algorithm: .sha256, bytes: Data(count: 32))
        let committed = Snapshot(
            id: snapshot.id,
            digest: committedDigest,
            size: snapshot.size,
            parent: snapshot.parent,
            state: .committed(
                layerDigest: committedDigest.stringValue,
                layerSize: snapshot.size,
                layerMediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
                diffKey: nil
            )
        )
        snapshots[snapshot.id] = committed
        return committed
    }

    public func remove(_ snapshot: Snapshot) async throws {
        snapshots.removeValue(forKey: snapshot.id)
        mounts.removeValue(forKey: snapshot.id)
    }

    public func mount(snapshot: Snapshot, at mountPoint: URL) async throws {
        mounts[snapshot.id] = mountPoint
    }

    public func unmount(snapshot: Snapshot) async throws {
        mounts.removeValue(forKey: snapshot.id)
    }

    public func getMountPoint(for snapshot: Snapshot) async -> URL? {
        mounts[snapshot.id]
    }

    public func list() async throws -> [Snapshot] {
        Array(snapshots.values)
    }

    public func get(id: UUID) async throws -> Snapshot? {
        snapshots[id]
    }

    public func getByDigest(_ digest: Digest) async throws -> Snapshot? {
        snapshots.values.first { $0.digest == digest }
    }
}
