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

@Suite struct TarArchiveDifferTests {

    private func makeDigest(_ s: String = "snap") -> Digest {
        let data = Data(s.utf8)
        return (try? Digest.compute(data, using: .sha256)) ?? (try! Digest(algorithm: .sha256, bytes: Data(count: 32)))
    }

    private func makePreparedSnapshot(at mount: URL, parent: Snapshot? = nil, tag: String = "snap") -> Snapshot {
        Snapshot(
            id: UUID(),
            digest: makeDigest(tag),
            size: 0,
            parent: parent,
            createdAt: Date(),
            state: .prepared(mountpoint: mount)
        )
    }

    @Test func diffScratchAndApplyRoundTrip() async throws {
        try await TestUtils.withTempDirAsync { tmp in
            let store = HashingContentStore()
            let differ = TarArchiveDiffer(contentStore: store)

            // Build target tree
            let target = tmp.appendingPathComponent("target", isDirectory: true)
            try TestUtils.mkdir(target)
            try TestUtils.writeString(target.appendingPathComponent("foo.txt"), "hello", permissions: 0o644)
            try TestUtils.mkdir(target.appendingPathComponent("dir"))
            try TestUtils.writeString(target.appendingPathComponent("dir/bar.txt"), "world")
            try TestUtils.makeSymlink(at: target.appendingPathComponent("ln"), to: "foo.txt")

            let snap = makePreparedSnapshot(at: target, tag: "target-1")

            // Compute diff from scratch
            let desc = try await differ.diff(base: nil, target: snap)
            #expect(desc.mediaType.contains("+gzip"))
            #expect(desc.size > 0)
            #expect(desc.digest.hasPrefix("sha256:"))

            // Verify blob is in content store and size matches
            let content = try await store.get(digest: desc.digest)
            #expect(content != nil)
            let bytes = try content!.data()
            #expect(Int64(bytes.count) == desc.size)

            // Apply to an empty root and compare
            let applyRoot = tmp.appendingPathComponent("apply-root", isDirectory: true)
            let tarFile = tmp.appendingPathComponent("layer.tar.gz")
            try bytes.write(to: tarFile)

            try differ.applyChain(to: applyRoot, layers: [(url: tarFile, mediaType: desc.mediaType)])

            // Spot-check files
            #expect(FileManager.default.fileExists(atPath: applyRoot.appendingPathComponent("foo.txt").path))
            #expect(FileManager.default.fileExists(atPath: applyRoot.appendingPathComponent("dir/bar.txt").path))

            // Compare contents
            let s1 = try String(decoding: Data(contentsOf: applyRoot.appendingPathComponent("foo.txt")), as: UTF8.self)
            let s2 = try String(decoding: Data(contentsOf: applyRoot.appendingPathComponent("dir/bar.txt")), as: UTF8.self)
            #expect(s1 == "hello")
            #expect(s2 == "world")
        }
    }

    @Test func deletionWhiteoutRemovesFilesOnApply() async throws {
        try await TestUtils.withTempDirAsync { tmp in
            let store = HashingContentStore()
            let differ = TarArchiveDiffer(contentStore: store)

            // Base tree
            let base = tmp.appendingPathComponent("base", isDirectory: true)
            try TestUtils.mkdir(base)
            try TestUtils.writeString(base.appendingPathComponent("keep.txt"), "keep")
            try TestUtils.writeString(base.appendingPathComponent("gone.txt"), "remove-me")

            // Target removes gone.txt
            let target = tmp.appendingPathComponent("target", isDirectory: true)
            try TestUtils.mkdir(target)
            // replicate base contents into target
            try TestUtils.writeString(target.appendingPathComponent("keep.txt"), "keep")
            // gone.txt is not created in target (simulating deletion)

            let baseSnap = makePreparedSnapshot(at: base, tag: "base")
            let targetSnap = makePreparedSnapshot(at: target, parent: baseSnap, tag: "target")

            let desc = try await differ.diff(base: baseSnap, target: targetSnap)

            // Seed an apply root with base contents
            let root = tmp.appendingPathComponent("root", isDirectory: true)
            try TestUtils.mkdir(root)
            try TestUtils.writeString(root.appendingPathComponent("keep.txt"), "keep")
            try TestUtils.writeString(root.appendingPathComponent("gone.txt"), "remove-me")

            // Fetch tar and apply
            let content = try await store.get(digest: desc.digest)
            #expect(content != nil)
            let bytes = try content!.data()
            let tar = tmp.appendingPathComponent("layer2.tar.gz")
            try bytes.write(to: tar)

            try differ.applyChain(to: root, layers: [(url: tar, mediaType: desc.mediaType)])

            // gone.txt should be removed; keep.txt preserved
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("gone.txt").path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
            let keep = try String(decoding: Data(contentsOf: root.appendingPathComponent("keep.txt")), as: UTF8.self)
            #expect(keep == "keep")
        }
    }

    @Test func zstdAndEstargzNotImplemented() {
        let store = HashingContentStore()
        let differ = TarArchiveDiffer(contentStore: store)
        #expect(throws: Error.self) {
            _ = try differ.archiveFilter(for: .zstd)
        }
        #expect(throws: Error.self) {
            _ = try differ.archiveFilter(for: .estargz)
        }
    }
}
