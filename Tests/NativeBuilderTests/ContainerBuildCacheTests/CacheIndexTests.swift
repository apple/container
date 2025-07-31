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
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerBuildCache

struct CacheIndexTests {

    @Test func putAndGet() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Create test data
        let key = "test-key-123"
        let descriptor = Descriptor(
            mediaType: "application/vnd.test+json",
            digest: "sha256:1234567890abcdef",
            size: 1024,
            urls: nil,
            annotations: nil,
            platform: nil
        )
        let platform = Platform(
            arch: "amd64",
            os: "linux",
        )
        let metadata = CacheMetadata(
            operationHash: "op-hash-123",
            platform: platform,
            ttl: 3600,
            tags: ["test": "true"]
        )

        // Test put
        try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)

        // Test get
        let entry = try await cacheIndex.get(key: key)
        #expect(entry != nil)
        #expect(entry?.descriptor.digest == descriptor.digest)
        #expect(entry?.metadata.operationHash == metadata.operationHash)

        // Test cache.json was created
        let cacheJsonPath = tempDir.appendingPathComponent("cache.json")
        #expect(FileManager.default.fileExists(atPath: cacheJsonPath.path) == true)
    }

    @Test func remove() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Add entries
        let keys = ["key1", "key2", "key3"]
        for key in keys {
            let descriptor = Descriptor(
                mediaType: "application/vnd.test+json",
                digest: "sha256:\(key)",
                size: 100,
                urls: nil,
                annotations: nil,
                platform: nil
            )
            let metadata = CacheMetadata(
                operationHash: "hash-\(key)",
                platform: Platform(arch: "amd64", os: "linux")
            )
            try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)
        }

        // Remove some entries
        try await cacheIndex.remove(keys: ["key1", "key3"])

        // Verify
        let entry1 = try await cacheIndex.get(key: "key1")
        let entry2 = try await cacheIndex.get(key: "key2")
        let entry3 = try await cacheIndex.get(key: "key3")

        #expect(entry1 == nil)
        #expect(entry2 != nil)
        #expect(entry3 == nil)
    }

    @Test func statistics() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Add some entries
        for i in 1...5 {
            let descriptor = Descriptor(
                mediaType: "application/vnd.test+json",
                digest: "sha256:entry\(i)",
                size: Int64(i * 1000),
                urls: nil,
                annotations: nil,
                platform: nil
            )
            let metadata = CacheMetadata(
                operationHash: "hash-\(i)",
                platform: Platform(arch: "amd64", os: "linux")
            )
            try await cacheIndex.put(key: "key\(i)", descriptor: descriptor, metadata: metadata)
        }

        // Get some entries to affect hit rate
        _ = try await cacheIndex.get(key: "key1")
        _ = try await cacheIndex.get(key: "key2")
        _ = try await cacheIndex.get(key: "key-missing")  // This should be a miss

        let stats = try await cacheIndex.statistics()

        #expect(stats.entryCount == 5)
        #expect(stats.totalSize == 15000)  // 1000 + 2000 + 3000 + 4000 + 5000
        #expect(stats.averageEntrySize == 3000)
        #expect(stats.hitRate > 0.6)  // 2 hits out of 3 attempts
    }

    @Test func allEntries() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Add entries
        let entries = [
            ("key1", "hash1"),
            ("key2", "hash2"),
            ("key3", "hash3"),
        ]

        for (key, hash) in entries {
            let descriptor = Descriptor(
                mediaType: "application/vnd.test+json",
                digest: "sha256:\(hash)",
                size: 100,
                urls: nil,
                annotations: nil,
                platform: nil
            )
            let metadata = CacheMetadata(
                operationHash: hash,
                platform: Platform(arch: "amd64", os: "linux")
            )
            try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)
        }

        // Get all entries
        let allEntries = try await cacheIndex.allEntries()

        #expect(allEntries.count == 3)
        #expect(allEntries["key1"] != nil)
        #expect(allEntries["key2"] != nil)
        #expect(allEntries["key3"] != nil)
    }

    @Test func persistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Add an entry
        let key = "persistent-key"
        let descriptor = Descriptor(
            mediaType: "application/vnd.test+json",
            digest: "sha256:persistent",
            size: 2048,
            urls: nil,
            annotations: nil,
            platform: nil
        )
        let metadata = CacheMetadata(
            operationHash: "persistent-hash",
            platform: Platform(arch: "arm64", os: "linux")
        )

        try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)

        // Create a new cache index with same path
        let newCacheIndex = try CacheIndex(path: tempDir)

        // Verify data persisted
        let entry = try await newCacheIndex.get(key: key)
        #expect(entry != nil)
        #expect(entry?.descriptor.digest == descriptor.digest)
        #expect(entry?.metadata.platform.os == "linux")
        #expect(entry?.metadata.platform.architecture == "arm64")
    }

    @Test func accessTimeUpdate() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        let key = "access-test"
        let descriptor = Descriptor(
            mediaType: "application/vnd.test+json",
            digest: "sha256:access",
            size: 512,
            urls: nil,
            annotations: nil,
            platform: nil
        )
        let metadata = CacheMetadata(
            operationHash: "access-hash",
            platform: Platform(arch: "amd64", os: "linux")
        )

        try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)

        // Get initial access time
        let entry1 = try await cacheIndex.get(key: key)
        let accessTime1 = entry1?.metadata.accessedAt

        // Wait a bit
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds

        // Access again
        let entry2 = try await cacheIndex.get(key: key)
        let accessTime2 = entry2?.metadata.accessedAt

        // Access time should be updated
        #expect(accessTime1 != nil)
        #expect(accessTime2 != nil)
        #expect(accessTime2! > accessTime1!)
    }

    // MARK: - Additional Tests for Concurrency, Large Datasets, and Error Handling

    @Test func cacheIndexConcurrentAccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        let entryCount = 50

        // Test concurrent puts and gets
        await withTaskGroup(of: Void.self) { group in
            // Concurrent puts
            for i in 0..<entryCount {
                group.addTask { [cacheIndex] in
                    let key = "concurrent-key-\(i)"
                    let descriptor = Descriptor(
                        mediaType: "application/vnd.test+json",
                        digest: "sha256:concurrent\(i)",
                        size: Int64(i * 100),
                        urls: nil,
                        annotations: nil,
                        platform: nil
                    )
                    let metadata = CacheMetadata(
                        operationHash: "concurrent-hash-\(i)",
                        platform: Platform(arch: "amd64", os: "linux")
                    )

                    try? await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)
                }
            }

            // Concurrent gets
            for i in 0..<entryCount {
                group.addTask { [cacheIndex] in
                    let key = "concurrent-key-\(i)"
                    _ = try? await cacheIndex.get(key: key)
                }
            }
        }

        // Verify all entries were stored correctly
        let allEntries = try await cacheIndex.allEntries()
        #expect(allEntries.count == entryCount)

        let stats = try await cacheIndex.statistics()
        #expect(stats.entryCount == entryCount)
        #expect(stats.hitRate > 0)
    }

    @Test func cacheIndexLargeDataSet() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        let largeEntryCount = 1000

        // Add a large number of entries
        for i in 0..<largeEntryCount {
            let key = "large-dataset-\(i)"
            let descriptor = Descriptor(
                mediaType: "application/vnd.test+json",
                digest: "sha256:\(String(format: "%064d", i))",
                size: Int64(i * 10),
                urls: nil,
                annotations: nil,
                platform: nil
            )
            let metadata = CacheMetadata(
                operationHash: "large-hash-\(i)",
                platform: Platform(arch: "amd64", os: "linux"),
                tags: ["batch": "large", "index": "\(i)"]
            )

            try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)
        }

        // Verify all entries are accessible
        let allEntries = try await cacheIndex.allEntries()
        #expect(allEntries.count == largeEntryCount)

        // Test random access
        let randomIndices = (0..<100).map { _ in Int.random(in: 0..<largeEntryCount) }
        for index in randomIndices {
            let key = "large-dataset-\(index)"
            let entry = try await cacheIndex.get(key: key)
            #expect(entry != nil)
            #expect(entry?.metadata.operationHash == "large-hash-\(index)")
        }

        // Verify statistics
        let stats = try await cacheIndex.statistics()
        #expect(stats.entryCount == largeEntryCount)
        #expect(stats.totalSize > 0)
        #expect(stats.hitRate > 0.9)  // Should have high hit rate
    }

    @Test func cacheIndexCorruptedIndexFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Add some entries first
        let key = "test-key"
        let descriptor = Descriptor(
            mediaType: "application/vnd.test+json",
            digest: "sha256:test",
            size: 1024,
            urls: nil,
            annotations: nil,
            platform: nil
        )
        let metadata = CacheMetadata(
            operationHash: "test-hash",
            platform: Platform(arch: "amd64", os: "linux")
        )

        try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)

        // Verify entry exists
        let entry1 = try await cacheIndex.get(key: key)
        #expect(entry1 != nil)

        // Corrupt the cache.json file
        let cacheJsonPath = tempDir.appendingPathComponent("cache.json")
        try "corrupted data".write(to: cacheJsonPath, atomically: true, encoding: .utf8)

        // Create a new cache index - should handle corruption gracefully
        let newCacheIndex = try CacheIndex(path: tempDir)

        // Should start with empty state
        let entry2 = try await newCacheIndex.get(key: key)
        #expect(entry2 == nil)  // Entry should be lost due to corruption

        // Should still be functional for new entries
        try await newCacheIndex.put(key: "new-key", descriptor: descriptor, metadata: metadata)
        let newEntry = try await newCacheIndex.get(key: "new-key")
        #expect(newEntry != nil)
    }

    @Test func cacheIndexStatisticsAccuracy() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Test that statistics are accurately maintained
        let initialStats = try await cacheIndex.statistics()
        #expect(initialStats.entryCount == 0)
        #expect(initialStats.totalSize == 0)
        #expect(initialStats.hitRate == 0.0)

        // Add entries with known sizes
        let entrySizes: [Int64] = [100, 200, 300, 400, 500]
        for (i, size) in entrySizes.enumerated() {
            let key = "stats-key-\(i)"
            let descriptor = Descriptor(
                mediaType: "application/vnd.test+json",
                digest: "sha256:stats\(i)",
                size: size,
                urls: nil,
                annotations: nil,
                platform: nil
            )
            let metadata = CacheMetadata(
                operationHash: "stats-hash-\(i)",
                platform: Platform(arch: "amd64", os: "linux")
            )

            try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)
        }

        // Check statistics after puts
        let afterPutStats = try await cacheIndex.statistics()
        #expect(afterPutStats.entryCount == entrySizes.count)
        #expect(afterPutStats.totalSize == UInt64(entrySizes.reduce(0, +)))
        let expectedAverage = UInt64(entrySizes.reduce(0, +)) / UInt64(entrySizes.count)
        #expect(afterPutStats.averageEntrySize == expectedAverage)

        // Perform some gets (hits and misses)
        _ = try await cacheIndex.get(key: "stats-key-0")  // Hit
        _ = try await cacheIndex.get(key: "stats-key-1")  // Hit
        _ = try await cacheIndex.get(key: "stats-key-2")  // Hit
        _ = try await cacheIndex.get(key: "nonexistent-1")  // Miss
        _ = try await cacheIndex.get(key: "nonexistent-2")  // Miss

        // Check final statistics
        let finalStats = try await cacheIndex.statistics()
        #expect(finalStats.entryCount == entrySizes.count)
        #expect(finalStats.totalSize == UInt64(entrySizes.reduce(0, +)))
        // Hit rate should be 3 hits out of 5 total operations (3 hits + 2 misses)
        #expect(abs(finalStats.hitRate - 3.0 / 5.0) < 0.001)
    }

    @Test func cacheIndexTTLExpiration() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheIndex = try CacheIndex(path: tempDir)

        // Test TTL-based expiration detection
        let key = "ttl-test"
        let descriptor = Descriptor(
            mediaType: "application/vnd.test+json",
            digest: "sha256:ttl",
            size: 1024,
            urls: nil,
            annotations: nil,
            platform: nil
        )

        // Create metadata with short TTL
        let now = Date()
        let metadata = CacheMetadata(
            createdAt: now,
            accessedAt: now,
            operationHash: "ttl-hash",
            platform: Platform(arch: "amd64", os: "linux"),
            ttl: 2.0  // 2 seconds to account for test execution time
        )

        try await cacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)

        // Immediately check - should not be expired
        let entry1 = try await cacheIndex.get(key: key)
        #expect(entry1 != nil)
        #expect(entry1!.metadata.isExpired == false)  // Entry should not be expired immediately after creation

        // Wait for TTL to expire
        try await Task.sleep(nanoseconds: 2_100_000_000)  // 2.1 seconds

        // Check expiration status
        let entry2 = try await cacheIndex.get(key: key)
        #expect(entry2 != nil)  // Entry still exists in index
        #expect(entry2!.metadata.isExpired == true)  // But is marked as expired
    }

    @Test func cacheIndexEmptyDirectory() async throws {
        // Test creating cache index in empty directory
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let emptyCacheIndex = try CacheIndex(path: emptyDir)

        // Should start with empty statistics
        let stats = try await emptyCacheIndex.statistics()
        #expect(stats.entryCount == 0)
        #expect(stats.totalSize == 0)

        // Should be functional
        let key = "empty-test"
        let descriptor = Descriptor(
            mediaType: "application/vnd.test+json",
            digest: "sha256:empty",
            size: 512,
            urls: nil,
            annotations: nil,
            platform: nil
        )
        let metadata = CacheMetadata(
            operationHash: "empty-hash",
            platform: Platform(arch: "amd64", os: "linux")
        )

        try await emptyCacheIndex.put(key: key, descriptor: descriptor, metadata: metadata)
        let entry = try await emptyCacheIndex.get(key: key)
        #expect(entry != nil)
    }
}
