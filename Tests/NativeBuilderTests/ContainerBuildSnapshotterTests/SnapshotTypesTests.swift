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
import Testing

@testable import ContainerBuildSnapshotter

@Suite struct SnapshotTypesTests {

    private func makeDigest(_ s: String = "hello") -> Digest {
        let data = Data(s.utf8)
        return (try? Digest.compute(data, using: .sha256)) ?? (try! Digest(algorithm: .sha256, bytes: Data(count: 32)))
    }

    @Test func stateHelperPropertiesPrepared() throws {
        let mp = URL(fileURLWithPath: "/tmp")  // just a placeholder URL
        let st = Snapshot.SnapshotState.prepared(mountpoint: mp)
        #expect(st.isPrepared)
        #expect(!st.isInProgress)
        #expect(!st.isCommitted)
        #expect(st.mountpoint == mp)
        #expect(st.layerDigest == nil)
        #expect(st.layerSize == nil)
        #expect(st.layerMediaType == nil)
        #expect(st.diffKey == nil)
        #expect(st.operationID == nil)
        #expect(st.canExecute)
        #expect(!st.isFinalized)
        #expect(!st.isLocked)
    }

    @Test func stateHelperPropertiesInProgress() throws {
        let op = UUID()
        let st = Snapshot.SnapshotState.inProgress(operationId: op)
        #expect(!st.isPrepared)
        #expect(st.isInProgress)
        #expect(!st.isCommitted)
        #expect(st.mountpoint == nil)
        #expect(st.operationID == op)
        #expect(!st.canExecute)
        #expect(!st.isFinalized)
        #expect(st.isLocked)
    }

    @Test func stateHelperPropertiesCommitted() throws {
        let st = Snapshot.SnapshotState.committed(
            layerDigest: "sha256:\(String(repeating: "a", count: 64))",
            layerSize: 123,
            layerMediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
            diffKey: try? DiffKey(parsing: "sha256:\(String(repeating: "b", count: 64))")
        )
        #expect(!st.isPrepared)
        #expect(!st.isInProgress)
        #expect(st.isCommitted)
        #expect(st.mountpoint == nil)
        #expect(st.layerDigest?.hasPrefix("sha256:") == true)
        #expect(st.layerSize == 123)
        #expect(st.layerMediaType == "application/vnd.oci.image.layer.v1.tar+gzip")
        #expect(st.diffKey?.stringValue.hasPrefix("sha256:") == true)
        #expect(st.operationID == nil)
        #expect(!st.canExecute)
        #expect(st.isFinalized)
        #expect(!st.isLocked)
    }

    @Test func snapshotInitialization() throws {
        let d = makeDigest("content")
        let parent = Snapshot(
            id: UUID(),
            digest: makeDigest("parent"),
            size: 10,
            parent: nil,
            createdAt: Date(timeIntervalSince1970: 1000),
            state: .committed(layerDigest: "sha256:\(String(repeating: "c", count: 64))")
        )
        let snap = Snapshot(
            id: UUID(),
            digest: d,
            size: 42,
            parent: parent,
            createdAt: Date(timeIntervalSince1970: 2000),
            state: .inProgress(operationId: UUID())
        )
        #expect(snap.digest == d)
        #expect(snap.size == 42)
        #expect(snap.parent?.digest.stringValue.hasPrefix("sha256:") == true)
    }

    @Test func snapshotCodableRoundTrip() throws {
        let dk = try DiffKey(parsing: "sha256:\(String(repeating: "d", count: 64))")
        let snap = Snapshot(
            id: UUID(),
            digest: makeDigest("x"),
            size: 77,
            parent: nil,
            createdAt: Date(timeIntervalSince1970: 12345),
            state: .committed(
                layerDigest: "sha256:\(String(repeating: "e", count: 64))",
                layerSize: 9876,
                layerMediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
                diffKey: dk
            )
        )

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snap)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let roundTripped = try dec.decode(Snapshot.self, from: data)

        #expect(roundTripped.digest == snap.digest)
        #expect(roundTripped.size == snap.size)
        #expect(roundTripped.state.isCommitted)
        #expect(roundTripped.state.layerDigest == snap.state.layerDigest)
        #expect(roundTripped.state.layerSize == snap.state.layerSize)
        #expect(roundTripped.state.layerMediaType == snap.state.layerMediaType)
        #expect(roundTripped.state.diffKey == snap.state.diffKey)
    }

    @Test func resourceLimitsDefault() {
        let rl = ResourceLimits()
        #expect(rl.maxInFlightBytes == 64 * 1024 * 1024)
        let custom = ResourceLimits(maxInFlightBytes: 1_000_000)
        #expect(custom.maxInFlightBytes == 1_000_000)
    }
}
