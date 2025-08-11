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

/// Pure unit tests for DiffKey that don't require DirectoryDiffer or filesystem operations.
/// These tests use mock Diff data to test DiffKey.computeFromDiffs() in isolation.
@Suite struct DiffKeyUnitTests {

    // MARK: - Mock Data Helpers

    /// Create a mock Added diff entry
    private func mockAdded(
        path: String,
        node: Diff.Modified.Node = .regular,
        permissions: FilePermissions? = FilePermissions(rawValue: 0o644),
        size: Int64? = 100,
        uid: UInt32? = 1000,
        gid: UInt32? = 1000,
        xattrs: [String: Data]? = nil
    ) -> Diff {
        .added(
            .init(
                path: BinaryPath(string: path),
                node: node,
                permissions: permissions,
                size: size,
                modificationTime: Date(timeIntervalSince1970: 1_000_000),
                linkTarget: nil,
                uid: uid,
                gid: gid,
                xattrs: xattrs,
                devMajor: nil,
                devMinor: nil,
                nlink: nil
            )
        )
    }

    /// Create a mock Modified diff entry
    private func mockModified(
        path: String,
        kind: Diff.Modified.Kind = .contentChanged,
        node: Diff.Modified.Node = .regular,
        permissions: FilePermissions? = FilePermissions(rawValue: 0o644),
        size: Int64? = 100,
        uid: UInt32? = 1000,
        gid: UInt32? = 1000,
        xattrs: [String: Data]? = nil
    ) -> Diff {
        .modified(
            .init(
                path: BinaryPath(string: path),
                kind: kind,
                node: node,
                permissions: permissions,
                size: size,
                modificationTime: Date(timeIntervalSince1970: 1_000_000),
                linkTarget: nil,
                uid: uid,
                gid: gid,
                xattrs: xattrs,
                devMajor: nil,
                devMinor: nil,
                nlink: nil
            )
        )
    }

    /// Create a mock Deleted diff entry
    private func mockDeleted(path: String) -> Diff {
        .deleted(path: BinaryPath(string: path))
    }

    // MARK: - Tests

    @Test func emptyDiffProducesConsistentKey() async throws {
        // Empty diffs should produce a consistent key
        let key1 = try await DiffKey.computeFromDiffs(
            [],
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let key2 = try await DiffKey.computeFromDiffs(
            [],
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(key1 == key2)
        #expect(key1.stringValue.hasPrefix("sha256:"))
    }

    @Test func singleAddedFileProducesKey() async throws {
        let diffs = [mockAdded(path: "file.txt")]

        let key = try await DiffKey.computeFromDiffs(
            diffs,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(key.stringValue.hasPrefix("sha256:"))
        #expect(key.rawHex.count == 64)
    }

    @Test func orderIndependentForSameChanges() async throws {
        // Same changes in different order should produce the same key
        let diffs1 = [
            mockAdded(path: "a.txt"),
            mockAdded(path: "b.txt"),
            mockAdded(path: "c.txt"),
        ]

        let diffs2 = [
            mockAdded(path: "c.txt"),
            mockAdded(path: "a.txt"),
            mockAdded(path: "b.txt"),
        ]

        let key1 = try await DiffKey.computeFromDiffs(
            diffs1,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let key2 = try await DiffKey.computeFromDiffs(
            diffs2,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(key1 == key2)
    }

    @Test func differentOperationTypesProduceDifferentKeys() async throws {
        let added = [mockAdded(path: "file.txt")]
        let modified = [mockModified(path: "file.txt")]
        let deleted = [mockDeleted(path: "file.txt")]

        let keyAdded = try await DiffKey.computeFromDiffs(
            added,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let keyModified = try await DiffKey.computeFromDiffs(
            modified,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let keyDeleted = try await DiffKey.computeFromDiffs(
            deleted,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(keyAdded != keyModified)
        #expect(keyModified != keyDeleted)
        #expect(keyAdded != keyDeleted)
    }

    @Test func differentModificationKindsProduceDifferentKeys() async throws {
        let contentChange = [mockModified(path: "file.txt", kind: .contentChanged)]
        let metadataOnly = [mockModified(path: "file.txt", kind: .metadataOnly)]
        let typeChange = [mockModified(path: "file.txt", kind: .typeChanged)]

        let keyContent = try await DiffKey.computeFromDiffs(
            contentChange,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let keyMetadata = try await DiffKey.computeFromDiffs(
            metadataOnly,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let keyType = try await DiffKey.computeFromDiffs(
            typeChange,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(keyContent != keyMetadata)
        #expect(keyMetadata != keyType)
        #expect(keyContent != keyType)
    }

    @Test func differentPermissionsProduceDifferentKeys() async throws {
        let perm644 = [mockAdded(path: "file.txt", permissions: FilePermissions(rawValue: 0o644))]
        let perm755 = [mockAdded(path: "file.txt", permissions: FilePermissions(rawValue: 0o755))]

        let key644 = try await DiffKey.computeFromDiffs(
            perm644,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let key755 = try await DiffKey.computeFromDiffs(
            perm755,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(key644 != key755)
    }

    @Test func xattrsAffectKey() async throws {
        let noXattrs = [mockAdded(path: "file.txt")]
        let withXattrs = [
            mockAdded(
                path: "file.txt",
                xattrs: ["user.test": Data("value".utf8)]
            )
        ]

        let keyNoXattrs = try await DiffKey.computeFromDiffs(
            noXattrs,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let keyWithXattrs = try await DiffKey.computeFromDiffs(
            withXattrs,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(keyNoXattrs != keyWithXattrs)
    }

    @Test func baseDigestAffectsKey() async throws {
        let diffs = [mockAdded(path: "file.txt")]
        let base1 = try Digest.compute(Data("base1".utf8), using: .sha256)
        let base2 = try Digest.compute(Data("base2".utf8), using: .sha256)

        let keyNoBase = try await DiffKey.computeFromDiffs(
            diffs,
            baseDigest: nil,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let keyBase1 = try await DiffKey.computeFromDiffs(
            diffs,
            baseDigest: base1,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let keyBase2 = try await DiffKey.computeFromDiffs(
            diffs,
            baseDigest: base2,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(keyNoBase != keyBase1)
        #expect(keyBase1 != keyBase2)
        #expect(keyNoBase != keyBase2)
    }

    @Test func coupleToBaseParameter() async throws {
        let diffs = [mockAdded(path: "file.txt")]
        let base = try Digest.compute(Data("base".utf8), using: .sha256)

        let keyCoupled = try await DiffKey.computeFromDiffs(
            diffs,
            baseDigest: base,
            targetMount: URL(fileURLWithPath: "/tmp"),
            coupleToBase: true
        )
        let keyUncoupled = try await DiffKey.computeFromDiffs(
            diffs,
            baseDigest: base,
            targetMount: URL(fileURLWithPath: "/tmp"),
            coupleToBase: false
        )

        #expect(keyCoupled != keyUncoupled)
    }

    @Test func complexDiffSetProducesConsistentKey() async throws {
        let diffs = [
            mockAdded(path: "new/file1.txt"),
            mockAdded(path: "new/file2.txt", node: .directory),
            mockModified(path: "existing/file.txt", kind: .contentChanged),
            mockModified(path: "existing/dir", kind: .metadataOnly, node: .directory),
            mockDeleted(path: "old/file.txt"),
            mockDeleted(path: "old/dir"),
            mockAdded(path: "link", node: .symlink),
        ]

        let key1 = try await DiffKey.computeFromDiffs(
            diffs,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let key2 = try await DiffKey.computeFromDiffs(
            diffs,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        #expect(key1 == key2)
    }

    @Test func socketsAndDevicesAreExcluded() async throws {
        // Sockets and device nodes should be excluded from the key
        let withSocketAndDevice = [
            mockAdded(path: "file.txt"),
            mockAdded(path: "socket", node: .socket),
            mockAdded(path: "device", node: .device),
        ]

        let withoutSocketAndDevice = [
            mockAdded(path: "file.txt")
        ]

        let key1 = try await DiffKey.computeFromDiffs(
            withSocketAndDevice,
            targetMount: URL(fileURLWithPath: "/tmp")
        )
        let key2 = try await DiffKey.computeFromDiffs(
            withoutSocketAndDevice,
            targetMount: URL(fileURLWithPath: "/tmp")
        )

        // Keys should be the same since sockets and devices are excluded
        #expect(key1 == key2)
    }
}
