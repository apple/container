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
import Testing

@testable import ContainerBuildSnapshotter

@Suite struct DirectoryDifferTests {

    @Test func scratchListsOnlyAdditions() async throws {
        try await TestUtils.withTempDirAsync { target in
            // Build a small tree
            let f1 = target.appendingPathComponent("a.txt")
            let f2 = target.appendingPathComponent("dir/b.txt")
            let l1 = target.appendingPathComponent("link")
            try TestUtils.writeString(f1, "hello")
            try TestUtils.writeString(f2, "world")
            try TestUtils.makeSymlink(at: l1, to: "a.txt")

            let differ = DirectoryDiffer()
            let changes = try await differ.diff(base: nil, target: target)

            // Expect 4 additions (dir, a.txt, dir/b.txt, link) depending on enumeration
            #expect(!changes.isEmpty)
            // All entries should be .added; order is path-sorted
            for c in changes {
                switch c {
                case .added(_): break
                default:
                    Issue.record("expected only .added entries in scratch mode, got \(c)")
                }
            }

            // Ensure known paths appear
            let paths = changes.map { c -> String in
                switch c {
                case .added(let a): return a.path.requireString
                case .modified(let m): return m.path.requireString
                case .deleted(let p): return p.requireString
                }
            }
            #expect(paths.contains("a.txt"))
            #expect(paths.contains("dir"))
            #expect(paths.contains("dir/b.txt"))
            #expect(paths.contains("link"))
        }
    }

    @Test func addModifyDeleteDetected() async throws {
        try await TestUtils.withTempDirAsync { root in
            let base = root.appendingPathComponent("base")
            let target = root.appendingPathComponent("target")
            try TestUtils.mkdir(base)
            try TestUtils.mkdir(target)

            // Base contents
            let keepBase = base.appendingPathComponent("keep.txt")
            let modBase = base.appendingPathComponent("mod.txt")
            let goneBase = base.appendingPathComponent("gone.txt")
            try TestUtils.writeString(keepBase, "keep")
            try TestUtils.writeString(modBase, "old")
            try TestUtils.writeString(goneBase, "delete-me")

            // Target: keep unchanged, modify mod.txt, delete gone.txt, add new.txt
            let keepT = target.appendingPathComponent("keep.txt")
            let modT = target.appendingPathComponent("mod.txt")
            let newT = target.appendingPathComponent("new.txt")

            // Create keep.txt with identical content
            try TestUtils.writeString(keepT, "keep")

            // Synchronize modification times to ensure no false positive
            let keepBaseAttrs = try FileManager.default.attributesOfItem(atPath: keepBase.path)
            if let modDate = keepBaseAttrs[.modificationDate] as? Date {
                try FileManager.default.setAttributes([.modificationDate: modDate], ofItemAtPath: keepT.path)
            }

            try TestUtils.writeString(modT, "NEW")  // ensure size changed to exercise content path
            try TestUtils.writeString(newT, "added")
            // gone.txt is not created in target (deleted)

            let differ = DirectoryDiffer()
            let changes = try await differ.diff(base: base, target: target)

            var added = Set<String>()
            var modified = Set<String>()
            var deleted = Set<String>()

            for c in changes {
                switch c {
                case .added(let a): added.insert(a.path.requireString)
                case .modified(let m): modified.insert(m.path.requireString)
                case .deleted(let p): deleted.insert(p.requireString)
                }
            }

            #expect(added.contains("new.txt"))
            #expect(modified.contains("mod.txt"))
            #expect(deleted.contains("gone.txt"))
        }
    }

    @Test func symlinkTargetChangeShownAsModified() async throws {
        try await TestUtils.withTempDirAsync { root in
            let base = root.appendingPathComponent("base2")
            let target = root.appendingPathComponent("target2")
            try TestUtils.mkdir(base)
            try TestUtils.mkdir(target)

            try TestUtils.writeString(base.appendingPathComponent("a.txt"), "x")
            try TestUtils.makeSymlink(at: base.appendingPathComponent("link"), to: "a.txt")

            try TestUtils.writeString(target.appendingPathComponent("a.txt"), "x")
            try TestUtils.makeSymlink(at: target.appendingPathComponent("link"), to: "a.txt")
            // Change symlink target
            try? FileManager.default.removeItem(at: target.appendingPathComponent("link"))
            try TestUtils.makeSymlink(at: target.appendingPathComponent("link"), to: "a.txt2")

            let differ = DirectoryDiffer()
            let changes = try await differ.diff(base: base, target: target)

            let symlinkMods = changes.compactMap { c -> String? in
                if case .modified(let m) = c, m.path.requireString == "link", m.kind == .symlinkTargetChanged {
                    return m.path.requireString
                }
                return nil
            }
            #expect(!symlinkMods.isEmpty)
        }
    }
}
