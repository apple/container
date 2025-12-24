//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerImagesService
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerImagesService

struct SnapshotStoreTests {

    @Test("getSnapshotSize should return 0 when snapshot directory does not exist")
    func testGetSnapshotSizeWhenSnapshotDoesNotExist() async throws {
        // prepare
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let snapshotStore = try SnapshotStore(
            path: tempDir,
            unpackStrategy: SnapshotStore.defaultUnpackStrategy,
            log: nil
        )

        // Create a descriptor for a non-existent snapshot
        let fakeDigest = "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        let platform = Platform(arch: "amd64", os: "linux")

        // Create descriptor directly with the properties
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: fakeDigest,
            size: 1024,
            platform: platform
        )

        let size = try await snapshotStore.getSnapshotSize(descriptor: descriptor)
        
        #expect(size == 0, "Expected size to be 0 when snapshot doesn't exist, got \(size)")
    }

    @Test("getSnapshotSize should return correct size when snapshot exists")
    func testGetSnapshotSizeWhenSnapshotExists() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let snapshotStore = try SnapshotStore(
            path: tempDir,
            unpackStrategy: SnapshotStore.defaultUnpackStrategy,
            log: nil
        )

        // Create a test descriptor
        let fakeDigest = "sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: fakeDigest,
            size: 1024,
            platform: Platform(arch: "amd64", os: "linux")
        )

        // Create snapshot directory
        let snapshotDir =
            tempDir
            .appendingPathComponent("snapshots")
            .appendingPathComponent(descriptor.digest.trimmingDigestPrefix)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        // Create test files: 1KB snapshot + 512 bytes info = 1536 bytes total
        let testFile = snapshotDir.appendingPathComponent("snapshot")
        try Data(repeating: 0, count: 1024).write(to: testFile)

        let infoFile = snapshotDir.appendingPathComponent("snapshot-info")
        try Data(repeating: 0, count: 512).write(to: infoFile)

        let size = try await snapshotStore.getSnapshotSize(descriptor: descriptor)

        #expect(size >= 1536, "Expected at least 1536 bytes (1024 + 512), got \(size) allocated")
    }

    @Test("getSnapshotSize should handle multiple files in snapshot directory")
    func testGetSnapshotSizeWithMultipleFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let snapshotStore = try SnapshotStore(
            path: tempDir,
            unpackStrategy: SnapshotStore.defaultUnpackStrategy,
            log: nil
        )

        let fakeDigest = "sha256:fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321"
        let platform = Platform(arch: "arm64", os: "linux")
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: fakeDigest,
            size: 2048,
            platform: platform
        )

        let snapshotDir =
            tempDir
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(descriptor.digest.trimmingDigestPrefix, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        // Create multiple files
        let file1 = snapshotDir.appendingPathComponent("snapshot", isDirectory: false)
        try Data(repeating: 1, count: 2048).write(to: file1)  // 2KB

        let file2 = snapshotDir.appendingPathComponent("snapshot-info", isDirectory: false)
        try Data(repeating: 2, count: 1024).write(to: file2)  // 1KB

        let subdir = snapshotDir.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file3 = subdir.appendingPathComponent("extra", isDirectory: false)
        try Data(repeating: 3, count: 512).write(to: file3)  // 512 bytes

        let expectedMinSize: UInt64 = 2048 + 1024 + 512  // 3.5KB

        let size = try await snapshotStore.getSnapshotSize(descriptor: descriptor)

        #expect(size >= expectedMinSize, "Expected size to include all files (at least \(expectedMinSize) bytes), got \(size)")
    }

    @Test("getSnapshotSize should handle empty snapshot directory")
    func testGetSnapshotSizeWithEmptyDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let snapshotStore = try SnapshotStore(
            path: tempDir,
            unpackStrategy: SnapshotStore.defaultUnpackStrategy,
            log: nil
        )

        let fakeDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        let platform = Platform(arch: "amd64", os: "linux")
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: fakeDigest,
            size: 0,
            platform: platform
        )

        // Create empty snapshot directory
        let snapshotDir =
            tempDir
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(descriptor.digest.trimmingDigestPrefix, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)


        let size = try await snapshotStore.getSnapshotSize(descriptor: descriptor)

        // Empty directory should return 0 or a small overhead value
        #expect(size >= 0, "Expected size to be non-negative, got \(size)")
    }
}
