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

@Suite struct TarArchiveSnapshotterTests {

    private func makeDigest(_ s: String = "snap") -> Digest {
        let data = Data(s.utf8)
        return (try? Digest.compute(data, using: .sha256)) ?? (try! Digest(algorithm: .sha256, bytes: Data(count: 32)))
    }

    private func preparedSnapshot(at mount: URL, parent: Snapshot? = nil, tag: String = "snap") -> Snapshot {
        Snapshot(
            id: UUID(),
            digest: makeDigest(tag),
            size: 0,
            parent: parent,
            createdAt: Date(),
            state: .prepared(mountpoint: mount)
        )
    }

    private func configuration(workingRoot: URL, store: HashingContentStore) -> TarArchiveSnapshotterConfiguration {
        let differ = TarArchiveDiffer(contentStore: store)
        return TarArchiveSnapshotterConfiguration(
            workingRoot: workingRoot,
            differ: differ,
            limits: ResourceLimits(),
            normalizeTimestamps: true
        )
    }

    @Test func commitFromScratchProducesCommittedSnapshot() async throws {
        try await TestUtils.withTempDirAsync { tmp in
            let work = tmp.appendingPathComponent("work", isDirectory: true)
            try TestUtils.mkdir(work)

            let store = HashingContentStore()
            let cfg = configuration(workingRoot: work, store: store)
            let snapshotter = TarArchiveSnapshotter(configuration: cfg)

            // Target tree
            let target = tmp.appendingPathComponent("target", isDirectory: true)
            try TestUtils.mkdir(target)
            try TestUtils.writeString(target.appendingPathComponent("file.txt"), "hello")

            let snap = preparedSnapshot(at: target, tag: "t1")

            let committed = try await snapshotter.commit(snap)
            #expect(committed.state.isCommitted)
            #expect(committed.state.layerDigest?.hasPrefix("sha256:") == true)
            #expect(committed.state.layerMediaType?.contains("+gzip") == true)
            #expect(committed.state.layerSize != nil)
            #expect(committed.state.diffKey?.stringValue.hasPrefix("sha256:") == true)

            // Ensure content exists in store for materialization
            let digest = committed.state.layerDigest!
            let content = try await store.get(digest: digest)
            #expect(content != nil)
            let size = try content!.size()
            #expect(Int64(size) == committed.state.layerSize)
        }
    }

    @Test func prepareWithCommittedParentMaterializesParent() async throws {
        try await TestUtils.withTempDirAsync { tmp in
            let work = tmp.appendingPathComponent("work", isDirectory: true)
            try TestUtils.mkdir(work)

            let store = HashingContentStore()
            let cfg = configuration(workingRoot: work, store: store)
            let snapshotter = TarArchiveSnapshotter(configuration: cfg)

            // Build and commit parent
            let parentDir = tmp.appendingPathComponent("parent", isDirectory: true)
            try TestUtils.mkdir(parentDir)
            try TestUtils.writeString(parentDir.appendingPathComponent("p.txt"), "parent")

            let parentPrepared = preparedSnapshot(at: parentDir, tag: "parent")
            let parentCommitted = try await snapshotter.commit(parentPrepared)
            #expect(parentCommitted.state.isCommitted)
            let parentLayerDigest = parentCommitted.state.layerDigest!
            let folderName = parentLayerDigest.replacingOccurrences(of: ":", with: "_")
            let matDir = work.appendingPathComponent("materialized/\(folderName)", isDirectory: true)

            // Create child snapshot with committed parent; call prepare(child)
            let childDir = tmp.appendingPathComponent("child", isDirectory: true)
            try TestUtils.mkdir(childDir)
            try TestUtils.writeString(childDir.appendingPathComponent("c.txt"), "child")

            let childPrepared = Snapshot(
                id: UUID(),
                digest: makeDigest("child"),
                size: 0,
                parent: parentCommitted,
                createdAt: Date(),
                state: .prepared(mountpoint: childDir)
            )

            // prepare should materialize committed parent into workingRoot/materialized/<digest>
            _ = try await snapshotter.prepare(childPrepared)
            // We cannot access snapshotter internals; assert that directory now exists (best-effort)
            #expect(FileManager.default.fileExists(atPath: matDir.path))
        }
    }

    @Test func commitWithPreparedParentUsesAsBase() async throws {
        try await TestUtils.withTempDirAsync { tmp in
            let work = tmp.appendingPathComponent("work", isDirectory: true)
            try TestUtils.mkdir(work)
            let store = HashingContentStore()
            let cfg = configuration(workingRoot: work, store: store)
            let snapshotter = TarArchiveSnapshotter(configuration: cfg)

            // Parent prepared (not committed)
            let parentDir = tmp.appendingPathComponent("parent-prepared", isDirectory: true)
            try TestUtils.mkdir(parentDir)
            try TestUtils.writeString(parentDir.appendingPathComponent("common.txt"), "same")
            let parentPrepared = preparedSnapshot(at: parentDir, tag: "parent-prepared")

            // Child adds a file
            let childDir = tmp.appendingPathComponent("child-prepared", isDirectory: true)
            try TestUtils.mkdir(childDir)
            try TestUtils.writeString(childDir.appendingPathComponent("common.txt"), "same")
            try TestUtils.writeString(childDir.appendingPathComponent("new.txt"), "added")
            let childPrepared = preparedSnapshot(at: childDir, parent: parentPrepared, tag: "child-prepared")

            let committed = try await snapshotter.commit(childPrepared)
            #expect(committed.state.isCommitted)
            #expect(committed.state.layerDigest?.hasPrefix("sha256:") == true)
            #expect(committed.state.diffKey != nil)
        }
    }

    @Test func commitBaseOverloadBindsDiffKeyToBaseDigest() async throws {
        try await TestUtils.withTempDirAsync { tmp in
            let work = tmp.appendingPathComponent("work", isDirectory: true)
            try TestUtils.mkdir(work)
            let store = HashingContentStore()
            let cfg = configuration(workingRoot: work, store: store)
            let snapshotter = TarArchiveSnapshotter(configuration: cfg)

            // Create a committed base snapshot (parent)
            let baseDir = tmp.appendingPathComponent("base", isDirectory: true)
            try TestUtils.mkdir(baseDir)
            try TestUtils.writeString(baseDir.appendingPathComponent("a.txt"), "A")
            let basePrepared = preparedSnapshot(at: baseDir, tag: "base")
            let baseCommitted = try await snapshotter.commit(basePrepared)
            #expect(baseCommitted.state.isCommitted)

            // New target snapshot without setting parent field; rely on explicit base: parameter
            let targetDir = tmp.appendingPathComponent("target", isDirectory: true)
            try TestUtils.mkdir(targetDir)
            try TestUtils.writeString(targetDir.appendingPathComponent("a.txt"), "A")  // same
            try TestUtils.writeString(targetDir.appendingPathComponent("b.txt"), "B")  // new
            let targetPrepared = preparedSnapshot(at: targetDir, tag: "target")

            let committed = try await snapshotter.commit(targetPrepared, base: baseCommitted)
            #expect(committed.state.isCommitted)
            #expect(committed.state.layerDigest?.hasPrefix("sha256:") == true)
            #expect(committed.state.diffKey?.stringValue.hasPrefix("sha256:") == true)
        }
    }

    @Test func removeDeletesPreparedMountpoint() async throws {
        try await TestUtils.withTempDirAsync { tmp in
            let work = tmp.appendingPathComponent("work", isDirectory: true)
            try TestUtils.mkdir(work)
            let store = HashingContentStore()
            let cfg = configuration(workingRoot: work, store: store)
            let snapshotter = TarArchiveSnapshotter(configuration: cfg)

            let mount = tmp.appendingPathComponent("mnt", isDirectory: true)
            try TestUtils.mkdir(mount)
            let snap = preparedSnapshot(at: mount, tag: "rem")
            #expect(FileManager.default.fileExists(atPath: mount.path))
            try await snapshotter.remove(snap)
            #expect(!FileManager.default.fileExists(atPath: mount.path))
        }
    }
}
