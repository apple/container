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

/// Integration tests for DiffKey that test the full pipeline from filesystem to DiffKey.
/// These tests use DirectoryDiffer to generate real diffs from filesystem operations.
/// For pure unit tests of DiffKey, see DiffKeyUnitTests.swift.
@Suite struct DiffKeyIntegrationTests {

    // Helper function to compute DiffKey using DirectoryDiffer first
    private func computeDiffKey(
        baseDigest: ContainerBuildIR.Digest? = nil,
        baseMount: URL? = nil,
        targetMount: URL,
        hasher: any ContentHasher = SHA256ContentHasher(),
        inspectorOptions: InspectorOptions = InspectorOptions(),
        coupleToBase: Bool = true
    ) async throws -> DiffKey {
        let directoryDiffer = DirectoryDiffer.makeDefault(
            hasher: hasher,
            options: inspectorOptions
        )

        let changes = try await directoryDiffer.diff(base: baseMount, target: targetMount)

        return try await DiffKey.computeFromDiffs(
            changes,
            baseDigest: baseDigest,
            baseMount: baseMount,
            targetMount: targetMount,
            hasher: hasher,
            coupleToBase: coupleToBase
        )
    }

    @Test func parsingValidation() {
        // valid
        #expect((try? DiffKey(parsing: "sha256:\(String(repeating: "a", count: 64))")) != nil)
        // invalid prefix
        #expect(throws: DiffKeyError.self) {
            _ = try DiffKey(parsing: "md5:\(String(repeating: "a", count: 32))")
        }
        // invalid hex
        #expect(throws: DiffKeyError.self) {
            _ = try DiffKey(parsing: "sha256:\(String(repeating: "g", count: 64))")
        }
        // invalid length
        #expect(throws: DiffKeyError.self) {
            _ = try DiffKey(parsing: "sha256:\(String(repeating: "a", count: 63))")
        }
    }

    @Test func deterministicForSameTree() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let t1 = dir.appendingPathComponent("t1", isDirectory: true)
            let t2 = dir.appendingPathComponent("t2", isDirectory: true)
            try TestUtils.mkdir(t1)
            try TestUtils.mkdir(t2)

            // Same contents/layout
            try TestUtils.writeString(t1.appendingPathComponent("a.txt"), "hello", permissions: 0o644)
            try TestUtils.mkdir(t1.appendingPathComponent("sub"))
            try TestUtils.writeString(t1.appendingPathComponent("sub/b.txt"), "world")

            try TestUtils.writeString(t2.appendingPathComponent("a.txt"), "hello", permissions: 0o644)
            try TestUtils.mkdir(t2.appendingPathComponent("sub"))
            try TestUtils.writeString(t2.appendingPathComponent("sub/b.txt"), "world")

            let k1 = try await computeDiffKey(targetMount: t1)
            let k2 = try await computeDiffKey(targetMount: t2)

            #expect(k1.stringValue.hasPrefix("sha256:"))
            #expect(k1 == k2)
        }
    }

    @Test func contentChangeAltersKey() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let t = dir.appendingPathComponent("t", isDirectory: true)
            try TestUtils.mkdir(t)
            let f = t.appendingPathComponent("a.txt")
            try TestUtils.writeString(f, "hello")

            let k1 = try await computeDiffKey(targetMount: t)

            // Change file bytes
            try TestUtils.writeString(f, "HELLO")
            let k2 = try await computeDiffKey(targetMount: t)

            #expect(k1 != k2)
        }
    }

    @Test func metadataChangePermissionsAltersKey() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let t = dir.appendingPathComponent("t", isDirectory: true)
            try TestUtils.mkdir(t)
            let f = t.appendingPathComponent("a.txt")
            try TestUtils.writeString(f, "same", permissions: 0o644)

            let k1 = try await computeDiffKey(targetMount: t)

            // Change mode only
            try TestUtils.chmod(f, mode: 0o600)
            let k2 = try await computeDiffKey(targetMount: t)

            // Permissions are included in canonical lines -> key must change
            #expect(k1 != k2)
        }
    }

    @Test func baseDigestAffectsKey() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let t = dir.appendingPathComponent("t", isDirectory: true)
            try TestUtils.mkdir(t)
            try TestUtils.writeString(t.appendingPathComponent("a.txt"), "data")

            let base1 = try Digest.compute(Data("base1".utf8), using: .sha256)
            let base2 = try Digest.compute(Data("base2".utf8), using: .sha256)

            let kScratch = try await computeDiffKey(targetMount: t)
            let kB1 = try await computeDiffKey(baseDigest: base1, targetMount: t)
            let kB2 = try await computeDiffKey(baseDigest: base2, targetMount: t)

            #expect(kScratch != kB1)
            #expect(kB1 != kB2)
        }
    }

    @Test func additionDeletionSymlinkTargetImpact() async throws {
        try await TestUtils.withTempDirAsync { dir in
            let t = dir.appendingPathComponent("t", isDirectory: true)
            try TestUtils.mkdir(t)
            try TestUtils.writeString(t.appendingPathComponent("a.txt"), "x")

            let k1 = try await computeDiffKey(targetMount: t)

            // Add a file
            try TestUtils.writeString(t.appendingPathComponent("b.txt"), "y")
            let kAdd = try await computeDiffKey(targetMount: t)
            #expect(k1 != kAdd)

            // Remove it again
            try FileManager.default.removeItem(at: t.appendingPathComponent("b.txt"))
            let kDel = try await computeDiffKey(targetMount: t)
            #expect(kAdd != kDel)
            #expect(k1 == kDel)  // back to original state

            // Symlink target change
            try TestUtils.makeSymlink(at: t.appendingPathComponent("link"), to: "a.txt")
            let kL1 = try await computeDiffKey(targetMount: t)
            try? FileManager.default.removeItem(at: t.appendingPathComponent("link"))
            try TestUtils.makeSymlink(at: t.appendingPathComponent("link"), to: "a2.txt")
            let kL2 = try await computeDiffKey(targetMount: t)
            #expect(kL1 != kL2)
        }
    }
}
