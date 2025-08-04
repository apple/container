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
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerBuildCache

struct BuildCacheProtocolTests {

    // MARK: - MemoryBuildCache Tests

    @Test func memoryBuildCacheBasicOperations() async throws {
        let cache = MemoryBuildCache()

        // Create test data
        let key = createTestCacheKey()
        let result = createTestCachedResult()
        let operation = createTestOperation()

        // Test cache miss
        let initialResult = await cache.get(key, for: operation)
        #expect(initialResult == nil)

        // Test put
        await cache.put(result, key: key, for: operation)

        // Test cache hit
        let cachedResult = await cache.get(key, for: operation)
        #expect(cachedResult != nil)
        #expect(cachedResult?.snapshot.id == result.snapshot.id)
        #expect(cachedResult?.environmentChanges.count == result.environmentChanges.count)
        #expect(cachedResult?.metadataChanges == result.metadataChanges)
    }

    @Test func memoryBuildCacheStatistics() async throws {
        let cache = MemoryBuildCache()

        // Initial statistics
        let initialStats = await cache.statistics()
        #expect(initialStats.entryCount == 0)
        #expect(initialStats.totalSize == 0)
        #expect(initialStats.hitRate == 0)

        // Add some entries
        let key1 = createTestCacheKey(operationDigest: "sha256:1111111111111111111111111111111111111111111111111111111111111111")
        let key2 = createTestCacheKey(operationDigest: "sha256:2222222222222222222222222222222222222222222222222222222222222222")
        let result = createTestCachedResult()
        let operation = createTestOperation()

        await cache.put(result, key: key1, for: operation)
        await cache.put(result, key: key2, for: operation)

        // Test statistics after adding entries
        let statsAfterPut = await cache.statistics()
        #expect(statsAfterPut.entryCount == 2)
        #expect(statsAfterPut.totalSize > 0)

        // Test hit rate calculation
        _ = await cache.get(key1, for: operation)  // Hit
        _ = await cache.get(key1, for: operation)  // Hit
        let nonExistentKey = createTestCacheKey(operationDigest: "sha256:9999999999999999999999999999999999999999999999999999999999999999")
        _ = await cache.get(nonExistentKey, for: operation)  // Miss

        let finalStats = await cache.statistics()
        #expect(abs(finalStats.hitRate - 2.0 / 3.0) < 0.01)  // 2 hits out of 3 attempts
    }

    @Test func memoryBuildCacheConcurrentAccess() async throws {
        let cache = MemoryBuildCache()
        let operation = createTestOperation()

        // Test concurrent puts and gets
        await withTaskGroup(of: Void.self) { group in
            // Concurrent puts
            for i in 0..<10 {
                let index = i
                let key = createTestCacheKey(operationDigest: "sha256:\(String(format: "%064d", index))")
                let result = createTestCachedResult()
                group.addTask { @Sendable in
                    await cache.put(result, key: key, for: operation)
                }
            }

            // Concurrent gets
            for i in 0..<10 {
                let index = i
                let key = createTestCacheKey(operationDigest: "sha256:\(String(format: "%064d", index))")
                group.addTask { @Sendable in
                    _ = await cache.get(key, for: operation)
                }
            }
        }

        let stats = await cache.statistics()
        #expect(stats.entryCount == 10)
    }

    // MARK: - NoOpBuildCache Tests

    @Test func noOpBuildCacheAlwaysReturnsNil() async throws {
        let cache = NoOpBuildCache()
        let key = createTestCacheKey()
        let result = createTestCachedResult()
        let operation = createTestOperation()

        // Test that get always returns nil
        let initialResult = await cache.get(key, for: operation)
        #expect(initialResult == nil)

        // Test that put doesn't store anything
        await cache.put(result, key: key, for: operation)

        // Test that get still returns nil after put
        let afterPutResult = await cache.get(key, for: operation)
        #expect(afterPutResult == nil)
    }

    @Test func noOpBuildCacheStatistics() async throws {
        let cache = NoOpBuildCache()

        let stats = await cache.statistics()
        #expect(stats.entryCount == 0)
        #expect(stats.totalSize == 0)
        #expect(stats.hitRate == 0)
        #expect(stats.oldestEntryAge == 0)
        #expect(stats.mostRecentEntryAge == 0)
    }

    // MARK: - CacheKey Tests

    @Test func cacheKeyEquality() throws {
        let digest1 = try Digest(parsing: "sha256:1111111111111111111111111111111111111111111111111111111111111111")
        let digest2 = try Digest(parsing: "sha256:2222222222222222222222222222222222222222222222222222222222222222")
        let platform = Platform.linuxAMD64

        let key1 = CacheKey(operationDigest: digest1, inputDigests: [digest2], platform: platform)
        let key2 = CacheKey(operationDigest: digest1, inputDigests: [digest2], platform: platform)
        let key3 = CacheKey(operationDigest: digest2, inputDigests: [digest1], platform: platform)

        #expect(key1 == key2)
        #expect(key1 != key3)
    }

    @Test func cacheKeyHashing() throws {
        let digest1 = try Digest(parsing: "sha256:1111111111111111111111111111111111111111111111111111111111111111")
        let digest2 = try Digest(parsing: "sha256:2222222222222222222222222222222222222222222222222222222222222222")
        let platform = Platform.linuxAMD64

        let key1 = CacheKey(operationDigest: digest1, inputDigests: [digest2], platform: platform)
        let key2 = CacheKey(operationDigest: digest1, inputDigests: [digest2], platform: platform)

        #expect(key1.hashValue == key2.hashValue)

        // Test that keys can be used in sets
        let keySet: Set<ContainerBuildCache.CacheKey> = [key1, key2]
        #expect(keySet.count == 1)  // Should deduplicate
    }

    // MARK: - CachedResult Tests

    @Test func cachedResultInitialization() throws {
        let snapshot = createTestSnapshot()
        let environmentChanges: [String: EnvironmentValue] = [
            "PATH": .literal("/usr/bin"),
            "HOME": .literal("/home/user"),
        ]
        let metadataChanges = ["build.time": "2024-01-01T12:00:00Z"]

        let result = CachedResult(
            snapshot: snapshot,
            environmentChanges: environmentChanges,
            metadataChanges: metadataChanges
        )

        #expect(result.snapshot.id == snapshot.id)
        #expect(result.environmentChanges.count == 2)
        #expect(result.metadataChanges["build.time"] == "2024-01-01T12:00:00Z")
    }

    // MARK: - Helper Methods

    private func createTestCacheKey(operationDigest: String = "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef") -> ContainerBuildCache.CacheKey {
        let digest = try! Digest(parsing: operationDigest)
        let inputDigest = try! Digest(parsing: "sha256:fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321")
        return ContainerBuildCache.CacheKey(
            operationDigest: digest,
            inputDigests: [inputDigest],
            platform: Platform.linuxAMD64
        )
    }

    private func createTestSnapshot() -> Snapshot {
        TestDataFactory.createSnapshot()
    }

    private func createTestCachedResult() -> CachedResult {
        TestDataFactory.createCachedResult()
    }

    private func createTestOperation() -> MockOperation {
        TestDataFactory.createOperation()
    }
}
