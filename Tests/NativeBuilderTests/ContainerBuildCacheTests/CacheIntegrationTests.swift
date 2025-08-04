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

struct CacheIntegrationTests {

    // MARK: - Complete Workflow Tests

    @Test func cacheIntegrationCompleteWorkflow() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let tempDir = testEnv.tempDir
            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let config = TestDataFactory.createCacheConfiguration(
                indexPath: tempDir.appendingPathComponent("workflow-cache")
            )

            // Initialize cache
            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: config
            )

            // Create test data
            let operation = TestDataFactory.createOperation(kind: "build", content: "compile-app")
            let key = TestDataFactory.createCacheKey(operationContent: "build-operation")
            let result = TestDataFactory.createCachedResult(
                snapshotContent: "compiled-app",
                environmentChanges: [
                    "PATH": .literal("/usr/local/bin:/usr/bin"),
                    "CC": .literal("clang"),
                ],
                metadataChanges: [
                    "build.time": "2024-01-01T12:00:00Z",
                    "build.version": "1.0.0",
                ]
            )

            // Step 1: Cache miss
            let initialResult = await cache.get(key, for: operation)
            #expect(initialResult == nil, "Initial cache lookup should miss")

            // Step 2: Store result
            await cache.put(result, key: key, for: operation)

            // Step 3: Cache hit
            let cachedResult = await cache.get(key, for: operation)
            #expect(cachedResult != nil, "Cache lookup should hit after storing")
            #expect(cachedResult?.snapshot.digest == result.snapshot.digest)
            #expect(cachedResult?.environmentChanges.count == result.environmentChanges.count)
            #expect(cachedResult?.metadataChanges == result.metadataChanges)

            // Step 4: Verify statistics
            let stats = await cache.statistics()
            #expect(stats.entryCount == 1)
            #expect(stats.totalSize > 0)
            #expect(stats.hitRate > 0)
        }
    }

    @Test func cacheIntegrationMultipleOperations() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let tempDir = testEnv.tempDir
            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let config = TestDataFactory.createCacheConfiguration(
                indexPath: tempDir.appendingPathComponent("multi-op-cache")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: config
            )

            // Simulate a multi-stage build process
            let operations = [
                ("download", "Download dependencies"),
                ("compile", "Compile source code"),
                ("test", "Run unit tests"),
                ("package", "Create distribution package"),
            ]

            var cachedResults: [CachedResult] = []

            // Store results for each operation
            for (i, (opType, opDescription)) in operations.enumerated() {
                let operation = TestDataFactory.createOperation(kind: opType, content: opDescription)
                let key = TestDataFactory.createCacheKey(
                    operationContent: "\(opType)-\(i)",
                    inputContents: i > 0 ? ["previous-stage-\(i-1)"] : []
                )
                let result = TestDataFactory.createCachedResult(
                    snapshotContent: "\(opType)-result-\(i)",
                    environmentChanges: ["STAGE": .literal(opType)],
                    metadataChanges: ["stage.name": opType, "stage.index": "\(i)"]
                )

                await cache.put(result, key: key, for: operation)
                cachedResults.append(result)
            }

            // Verify all operations are cached
            for (i, (opType, opDescription)) in operations.enumerated() {
                let operation = TestDataFactory.createOperation(kind: opType, content: opDescription)
                let key = TestDataFactory.createCacheKey(
                    operationContent: "\(opType)-\(i)",
                    inputContents: i > 0 ? ["previous-stage-\(i-1)"] : []
                )

                let cachedResult = await cache.get(key, for: operation)
                #expect(cachedResult != nil, "Operation \(opType) should be cached")
                #expect(cachedResult?.snapshot.digest == cachedResults[i].snapshot.digest)
            }

            // Verify final statistics
            let stats = await cache.statistics()
            #expect(stats.entryCount == operations.count)
            #expect(stats.totalSize > 0)
        }
    }

    @Test func cacheIntegrationPersistenceAcrossRestarts() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let indexPath = testEnv.tempDir.appendingPathComponent("persistent-cache")
            let config = TestDataFactory.createCacheConfiguration(indexPath: indexPath)

            let operation = TestDataFactory.createOperation()
            let key = TestDataFactory.createCacheKey()
            let result = TestDataFactory.createCachedResult()

            // First cache instance
            do {
                let cache1 = try await ContentAddressableCache(
                    contentStore: mockContentStore,
                    configuration: config
                )

                await cache1.put(result, key: key, for: operation)

                let cachedResult1 = await cache1.get(key, for: operation)
                #expect(cachedResult1 != nil)
            }

            // Second cache instance (simulating restart)
            do {
                let cache2 = try await ContentAddressableCache(
                    contentStore: mockContentStore,
                    configuration: config
                )

                // Should still find the cached result
                let cachedResult2 = await cache2.get(key, for: operation)
                #expect(cachedResult2 != nil, "Cache should persist across restarts")
                #expect(cachedResult2?.snapshot.digest == result.snapshot.digest)
            }
        }
    }

    @Test func cacheIntegrationLargeDataSets() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let config = TestDataFactory.createCacheConfiguration(
                maxSize: 10 * 1024 * 1024,  // 10MB
                indexPath: testEnv.tempDir.appendingPathComponent("large-data-cache")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: config
            )

            let operation = TestDataFactory.createOperation()
            let entryCount = 100

            // Store many entries
            for i in 0..<entryCount {
                let key = TestDataFactory.createCacheKey(operationContent: "large-dataset-\(i)")
                let result = TestDataFactory.createCachedResult(
                    snapshotContent: String(repeating: "data-\(i)-", count: 100)  // Larger content
                )

                await cache.put(result, key: key, for: operation)
            }

            // Verify some entries are still accessible
            var foundEntries = 0
            for i in 0..<entryCount {
                let key = TestDataFactory.createCacheKey(operationContent: "large-dataset-\(i)")
                let cachedResult = await cache.get(key, for: operation)
                if cachedResult != nil {
                    foundEntries += 1
                }
            }

            // Due to eviction, we might not have all entries, but should have some
            #expect(foundEntries > 0, "Should have at least some cached entries")

            let stats = await cache.statistics()
            #expect(stats.totalSize <= config.maxSize * 2)  // Allow some overhead
        }
    }

    @Test func cacheIntegrationErrorRecovery() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let config = TestDataFactory.createCacheConfiguration(
                indexPath: testEnv.tempDir.appendingPathComponent("error-recovery-cache")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: config
            )

            let operation = TestDataFactory.createOperation()

            // Store some valid entries
            for i in 0..<5 {
                let key = TestDataFactory.createCacheKey(operationContent: "valid-entry-\(i)")
                let result = TestDataFactory.createCachedResult(snapshotContent: "valid-content-\(i)")
                await cache.put(result, key: key, for: operation)
            }

            // Verify cache is working
            let stats1 = await cache.statistics()
            #expect(stats1.entryCount == 5)

            // Simulate error condition by clearing content store but keeping index
            await mockContentStore.clear()

            // Cache should handle missing content gracefully
            let key = TestDataFactory.createCacheKey(operationContent: "valid-entry-0")
            let _ = await cache.get(key, for: operation)
            // Result should be nil due to missing content, but cache shouldn't crash

            // Cache should still be functional for new entries
            let newKey = TestDataFactory.createCacheKey(operationContent: "new-entry")
            let newResult = TestDataFactory.createCachedResult(snapshotContent: "new-content")
            await cache.put(newResult, key: newKey, for: operation)

            let cachedNewResult = await cache.get(newKey, for: operation)
            #expect(cachedNewResult != nil, "Cache should recover and work for new entries")
        }
    }

    // MARK: - Cross-Cache Type Integration

    @Test func cacheIntegrationMemoryCacheComparison() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let memoryCache = MemoryBuildCache()

            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let config = TestDataFactory.createCacheConfiguration(
                indexPath: testEnv.tempDir.appendingPathComponent("comparison-cache")
            )
            let persistentCache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: config
            )

            let operation = TestDataFactory.createOperation()
            let key = TestDataFactory.createCacheKey()
            let result = TestDataFactory.createCachedResult()

            // Store in both caches
            await memoryCache.put(result, key: key, for: operation)
            await persistentCache.put(result, key: key, for: operation)

            // Retrieve from both caches
            let memoryResult = await memoryCache.get(key, for: operation)
            let persistentResult = await persistentCache.get(key, for: operation)

            // Both should return the same logical result
            #expect(memoryResult != nil)
            #expect(persistentResult != nil)
            #expect(memoryResult?.snapshot.digest == persistentResult?.snapshot.digest)
            #expect(memoryResult?.environmentChanges.count == persistentResult?.environmentChanges.count)
            #expect(memoryResult?.metadataChanges == persistentResult?.metadataChanges)

            // Compare statistics
            let memoryStats = await memoryCache.statistics()
            let persistentStats = await persistentCache.statistics()

            #expect(memoryStats.entryCount == persistentStats.entryCount)
            // Note: totalSize might differ due to different storage mechanisms
        }
    }

    // MARK: - Performance Integration Tests

    @Test func cacheIntegrationPerformanceUnderLoad() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let config = TestDataFactory.createCacheConfiguration(
                maxSize: 50 * 1024 * 1024,  // 50MB
                indexPath: testEnv.tempDir.appendingPathComponent("performance-cache")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: config
            )

            let operation = TestDataFactory.createOperation()
            let operationCount = 50

            // Measure performance under concurrent load
            let (_, duration) = await PerformanceMeasurement.measure {
                // First, perform concurrent writes
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<operationCount {
                        group.addTask {
                            let key = TestDataFactory.createCacheKey(operationContent: "perf-test-\(i)")
                            let result = TestDataFactory.createCachedResult(snapshotContent: "content-\(i)")
                            await cache.put(result, key: key, for: operation)
                        }
                    }
                }

                // Then, perform concurrent reads
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<operationCount {
                        group.addTask {
                            let key = TestDataFactory.createCacheKey(operationContent: "perf-test-\(i)")
                            _ = await cache.get(key, for: operation)
                        }
                    }
                }
            }

            // Assert reasonable performance
            #expect(duration < 10.0, "Cache operations under load took too long: \(duration)s")

            let stats = await cache.statistics()
            #expect(stats.entryCount > 0)
            #expect(stats.hitRate > 0)
        }
    }

    // MARK: - Real-World Scenario Tests

    @Test func cacheIntegrationBuildPipelineScenario() async throws {
        try await withCacheTestEnvironment { (testEnv: CacheTestEnvironment) in
            let mockContentStore = MockContentStore(baseDir: testEnv.tempDir)
            let config = TestDataFactory.createCacheConfiguration(
                indexPath: testEnv.tempDir.appendingPathComponent("pipeline-cache")
            )

            let cache = try await ContentAddressableCache(
                contentStore: mockContentStore,
                configuration: config
            )

            // Simulate a typical build pipeline
            let pipeline = [
                ("fetch-sources", ["Dockerfile", "src/"]),
                ("install-deps", ["package.json", "yarn.lock"]),
                ("compile", ["src/main.ts", "src/utils.ts"]),
                ("test", ["test/unit.test.ts"]),
                ("build-image", ["dist/", "Dockerfile"]),
            ]

            var previousOutputs: [String] = []

            for (stageName, inputs) in pipeline {
                let operation = TestDataFactory.createOperation(kind: stageName, content: "Pipeline stage: \(stageName)")
                let key = TestDataFactory.createCacheKey(
                    operationContent: stageName,
                    inputContents: inputs + previousOutputs
                )

                // Check cache first
                let cachedResult = await cache.get(key, for: operation)

                if cachedResult != nil {
                    // Cache hit - use cached result
                    previousOutputs.append("cached-\(stageName)")
                    print("Cache hit for stage: \(stageName)")
                } else {
                    // Cache miss - simulate work and store result
                    let result = TestDataFactory.createCachedResult(
                        snapshotContent: "output-of-\(stageName)",
                        environmentChanges: ["STAGE": .literal(stageName)],
                        metadataChanges: [
                            "stage": stageName,
                            "timestamp": ISO8601DateFormatter().string(from: Date()),
                        ]
                    )

                    await cache.put(result, key: key, for: operation)
                    previousOutputs.append("fresh-\(stageName)")
                    print("Cache miss for stage: \(stageName)")
                }
            }

            // Verify all stages were processed
            #expect(previousOutputs.count == pipeline.count)

            // Run pipeline again - should have more cache hits
            var secondRunOutputs: [String] = []
            previousOutputs = []  // Reset for second run

            for (stageName, inputs) in pipeline {
                let operation = TestDataFactory.createOperation(kind: stageName, content: "Pipeline stage: \(stageName)")
                let key = TestDataFactory.createCacheKey(
                    operationContent: stageName,
                    inputContents: inputs + previousOutputs
                )

                let cachedResult = await cache.get(key, for: operation)
                if cachedResult != nil {
                    secondRunOutputs.append("cached-\(stageName)")
                    previousOutputs.append("cached-\(stageName)")
                } else {
                    secondRunOutputs.append("fresh-\(stageName)")
                    previousOutputs.append("fresh-\(stageName)")
                }
            }

            // Second run should have at least some cache hits
            let cacheHits = secondRunOutputs.filter { $0.hasPrefix("cached-") }.count
            #expect(cacheHits > 0, "Second pipeline run should have cache hits")

            let finalStats = await cache.statistics()
            #expect(finalStats.hitRate > 0, "Overall hit rate should be positive")
        }
    }
}
