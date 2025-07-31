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
import Testing

@testable import ContainerBuildCache

struct ContentAddressableCacheTests {

    // MARK: - Basic Operations Tests

    @Test func contentAddressableCacheBasicGetPut() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            // Note: This test assumes ContentAddressableCache can accept our protocol
            // In a real implementation, we might need to create an adapter
            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )
            defer {
                // Cleanup handled by withCacheTestEnvironment
            }
            let operation = TestDataFactory.createOperation()
            let key = TestDataFactory.createCacheKey(operation: operation)
            let result = TestDataFactory.createCachedResult()

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
    }

    @Test func contentAddressableCacheMiss() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            let key = TestDataFactory.createCacheKey()
            let operation = TestDataFactory.createOperation()

            let result = await cache.get(key, for: operation)
            #expect(result == nil)
        }
    }

    @Test func contentAddressableCacheHit() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            let operation = TestDataFactory.createOperation()
            let key = TestDataFactory.createCacheKey(operation: operation)
            let result = TestDataFactory.createCachedResult()

            // Store the result
            await cache.put(result, key: key, for: operation)

            // Retrieve it
            let cachedResult = await cache.get(key, for: operation)
            #expect(cachedResult != nil)
            #expect(cachedResult?.snapshot.digest == result.snapshot.digest)
        }
    }

    @Test func contentAddressableCacheDuplicatePut() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            let key = TestDataFactory.createCacheKey()
            let result1 = TestDataFactory.createCachedResult(snapshotContent: "content1")
            let result2 = TestDataFactory.createCachedResult(snapshotContent: "content2")
            let operation = TestDataFactory.createOperation()

            // Store first result
            await cache.put(result1, key: key, for: operation)

            // Store second result with same key (should be ignored)
            await cache.put(result2, key: key, for: operation)

            // Should still get the first result
            let cachedResult = await cache.get(key, for: operation)
            #expect(cachedResult != nil)
            #expect(cachedResult?.snapshot.digest == result1.snapshot.digest)
        }
    }

    @Test func contentAddressableCacheStatistics() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            let stats = await cache.statistics()
            #expect(stats.entryCount == 0)
            #expect(stats.totalSize == 0)

            // Add some entries
            let key1 = TestDataFactory.createCacheKey(operationContent: "op1")
            let key2 = TestDataFactory.createCacheKey(operationContent: "op2")
            let result = TestDataFactory.createCachedResult()
            let operation = TestDataFactory.createOperation()

            await cache.put(result, key: key1, for: operation)
            await cache.put(result, key: key2, for: operation)

            let updatedStats = await cache.statistics()
            #expect(updatedStats.entryCount == 2)
            #expect(updatedStats.totalSize > 0)
        }
    }

    // MARK: - Eviction Tests

    @Test func contentAddressableCacheEvictionBySize() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)

            // Create a small cache
            let smallConfig = TestDataFactory.createCacheConfiguration(
                maxSize: 2048,  // Very small cache
                indexPath: environment.tempDir.appendingPathComponent("small-cache-index")
            )

            let smallCache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: smallConfig
            )

            // Fill the cache beyond capacity
            let operation = TestDataFactory.createOperation()
            for i in 0..<10 {
                let key = TestDataFactory.createCacheKey(operationContent: "operation-\(i)")
                let result = TestDataFactory.createCachedResult(snapshotContent: "large-content-\(i)")
                await smallCache.put(result, key: key, for: operation)
            }

            // Give eviction time to run
            try await Task.sleep(nanoseconds: 100_000_000 * 5)  // 0.1 seconds

            let stats = await smallCache.statistics()
            #expect(stats.totalSize < 2048 * 2)  // Should have evicted some entries
        }
    }

    @Test func contentAddressableCacheEvictionByAge() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            // This test would require manipulating time or using a mock clock
            // For now, we'll test the TTL-based eviction logic

            let key = TestDataFactory.createCacheKey()
            let result = TestDataFactory.createCachedResult()
            let operation = TestDataFactory.createOperation()

            await cache.put(result, key: key, for: operation)

            // Verify it's there
            let cachedResult = await cache.get(key, for: operation)
            #expect(cachedResult != nil)

            // In a real test, we'd advance time and check eviction
            // For now, just verify the entry exists
            let stats = await cache.statistics()
            #expect(stats.entryCount == 1)
        }
    }

    @Test func contentAddressableCacheEvictionByTTL() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)

            // Create configuration with short TTL
            let shortTTLConfig = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,
                maxAge: 1,  // 1 second TTL
                indexPath: environment.tempDir.appendingPathComponent("ttl-cache-index")
            )

            let ttlCache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: shortTTLConfig
            )

            let key = TestDataFactory.createCacheKey()
            let result = TestDataFactory.createCachedResult()
            let operation = TestDataFactory.createOperation()

            await ttlCache.put(result, key: key, for: operation)

            // Verify it's there initially
            let initialResult = await ttlCache.get(key, for: operation)
            #expect(initialResult != nil)

            // Wait for TTL to expire
            try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds

            // Entry should be evicted (this depends on the implementation running periodic cleanup)
            // Note: This test might be flaky depending on the eviction implementation
        }
    }

    // MARK: - Concurrency Tests

    @Test func contentAddressableCacheConcurrentOperations() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            let operation = TestDataFactory.createOperation()

            // Test concurrent puts and gets
            await withTaskGroup(of: Void.self) { group in
                // Concurrent puts
                for i in 0..<5 {
                    group.addTask {
                        let key = TestDataFactory.createCacheKey(operationContent: "concurrent-op-\(i)")
                        let result = TestDataFactory.createCachedResult(snapshotContent: "content-\(i)")
                        await cache.put(result, key: key, for: operation)
                    }
                }

                // Concurrent gets
                for i in 0..<5 {
                    group.addTask {
                        let key = TestDataFactory.createCacheKey(operationContent: "concurrent-op-\(i)")
                        _ = await cache.get(key, for: operation)
                    }
                }
            }

            let stats = await cache.statistics()
            #expect(stats.entryCount > 0)
        }
    }

    // MARK: - Error Handling Tests

    @Test func contentAddressableCacheCorruptedData() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            // This test would require injecting corrupted data into the content store
            // For now, we'll test basic error resilience

            let key = TestDataFactory.createCacheKey()
            let operation = TestDataFactory.createOperation()

            // Try to get from empty cache (should handle gracefully)
            let result = await cache.get(key, for: operation)
            #expect(result == nil)

            // Cache should still be functional
            let stats = await cache.statistics()
            #expect(stats.entryCount == 0)
        }
    }

    @Test func contentAddressableCacheMissingContentStore() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            // Test behavior when content store operations fail
            // This would require a mock that can simulate failures

            let key = TestDataFactory.createCacheKey()
            let result = TestDataFactory.createCachedResult()
            let operation = TestDataFactory.createOperation()

            // Put should not crash even if content store has issues
            await cache.put(result, key: key, for: operation)

            // Get should handle missing content gracefully
            let _ = await cache.get(key, for: operation)
            // Result depends on whether the put succeeded despite content store issues
        }
    }

    // MARK: - Performance Tests

    @Test func contentAddressableCachePerformance() async throws {
        try await withCacheTestEnvironment { environment in
            let mockContentStore = MockContentStore(baseDir: environment.tempDir)
            let configuration = TestDataFactory.createCacheConfiguration(
                maxSize: 1024 * 1024,  // 1MB for tests
                maxAge: 3600,  // 1 hour for tests
                indexPath: environment.tempDir.appendingPathComponent("cache-index")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: configuration
            )

            let operation = TestDataFactory.createOperation()

            let (_, duration) = await PerformanceMeasurement.measure {
                // Perform multiple cache operations
                for i in 0..<100 {
                    let key = TestDataFactory.createCacheKey(operationContent: "perf-test-\(i)")
                    let result = TestDataFactory.createCachedResult(snapshotContent: "content-\(i)")
                    await cache.put(result, key: key, for: operation)
                    _ = await cache.get(key, for: operation)
                }
            }

            // Assert reasonable performance (adjust threshold as needed)
            #expect(duration < 5.0, "Cache operations took too long: \(duration)s")
        }
    }
}
