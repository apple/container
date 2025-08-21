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

struct ContentAddressableCacheTests {

    // Helper to create a cache with a mock store and isolated index directory
    private func makeCache(
        tempDir: URL,
        store: MockContentStore? = nil,
        ttl: TimeInterval? = nil,
        gcInterval: TimeInterval = 10.0
    ) async throws -> (ContentAddressableCache, MockContentStore) {
        let indexPath = tempDir.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexPath, withIntermediateDirectories: true)

        let contentStore = store ?? MockContentStore(baseDir: tempDir.appendingPathComponent("store", isDirectory: true))
        let config = CacheConfiguration(
            maxSize: 1024 * 1024 * 1024,
            maxAge: 7 * 24 * 60 * 60,
            indexPath: indexPath,
            evictionPolicy: .lru,
            concurrency: .default,
            verifyIntegrity: true,
            sharding: nil,
            gcInterval: gcInterval,
            cacheKeyVersion: "test-v1",
            defaultTTL: ttl
        )

        let cache = try await ContentAddressableCache(contentStore: contentStore, configuration: config)
        return (cache, contentStore)
    }

    @Test func putAndGetRoundTrip() async throws {
        try await withCacheTestEnvironment { env in
            let (cache, store) = try await makeCache(tempDir: env.tempDir)

            let op = TestDataFactory.createOperation(kind: "run", content: "echo hello")
            let key = TestDataFactory.createCacheKey(operation: op, inputContents: ["in1", "in2"], platform: .linuxAMD64)
            let result = TestDataFactory.createCachedResult(
                snapshotContent: "snap-A",
                environmentChanges: ["PATH": .literal("/usr/bin:/bin")],
                metadataChanges: ["build.time": "2024-08-01T00:00:00Z"]
            )

            await cache.put(result, key: key, for: op)

            // Stored once in content store
            #expect(await store.contentCount() == 1)

            let fetched = await cache.get(key, for: op)
            let fr = try #require(fetched)

            // Verify snapshot and metadata round-trip
            #expect(fr.snapshot.digest == result.snapshot.digest)
            #expect(fr.snapshot.size == result.snapshot.size)
            #expect(fr.environmentChanges == result.environmentChanges)
            #expect(fr.metadataChanges == result.metadataChanges)
        }
    }

    @Test func idempotentPutDoesNotDuplicateStorage() async throws {
        try await withCacheTestEnvironment { env in
            let (cache, store) = try await makeCache(tempDir: env.tempDir)

            let op = TestDataFactory.createOperation(kind: "run", content: "op-idem")
            let key = TestDataFactory.createCacheKey(operation: op, inputContents: ["a", "b"], platform: .linuxAMD64)
            let result = TestDataFactory.createCachedResult(snapshotContent: "idem-snap")

            await cache.put(result, key: key, for: op)
            await cache.put(result, key: key, for: op)  // second put should be a no-op

            #expect(await store.contentCount() == 1)
        }
    }

    @Test func hasKeyAndMiss() async throws {
        try await withCacheTestEnvironment { env in
            let (cache, _) = try await makeCache(tempDir: env.tempDir)

            let op = TestDataFactory.createOperation(kind: "cmd", content: "A")
            let keyHit = TestDataFactory.createCacheKey(operation: op, inputContents: ["x"], platform: .linuxAMD64)
            let keyMiss = TestDataFactory.createCacheKey(operation: op, inputContents: ["different"], platform: .linuxAMD64)

            let result = TestDataFactory.createCachedResult(snapshotContent: "rt")
            await cache.put(result, key: keyHit, for: op)

            #expect(await cache.has(key: keyHit))
            #expect(!(await cache.has(key: keyMiss)))
        }
    }

    @Test func deterministicKeyOrderInvariance() async throws {
        try await withCacheTestEnvironment { env in
            let (cache, store) = try await makeCache(tempDir: env.tempDir)

            let op = TestDataFactory.createOperation(kind: "run", content: "det")
            // Same set of inputs but different order
            let key1 = TestDataFactory.createCacheKey(operation: op, inputContents: ["i1", "i2", "i3"], platform: .linuxAMD64)
            let key2 = TestDataFactory.createCacheKey(operation: op, inputContents: ["i3", "i2", "i1"], platform: .linuxAMD64)
            let result = TestDataFactory.createCachedResult(snapshotContent: "det-snap")

            await cache.put(result, key: key1, for: op)

            // Expect that the permuted key hits the same entry (no additional storage)
            #expect(await cache.has(key: key2))
            let fetched = await cache.get(key2, for: op)
            #expect(fetched?.snapshot.digest == result.snapshot.digest)
            #expect(await store.contentCount() == 1)
        }
    }

    @Test func evictRemovesIndexAndContent() async throws {
        try await withCacheTestEnvironment { env in
            let (cache, store) = try await makeCache(tempDir: env.tempDir)

            let op = TestDataFactory.createOperation(kind: "run", content: "evict-op")
            let key1 = TestDataFactory.createCacheKey(operation: op, inputContents: ["k1"], platform: .linuxAMD64)
            let key2 = TestDataFactory.createCacheKey(operation: op, inputContents: ["k2"], platform: .linuxAMD64)
            let r1 = TestDataFactory.createCachedResult(snapshotContent: "S1")
            let r2 = TestDataFactory.createCachedResult(snapshotContent: "S2")

            await cache.put(r1, key: key1, for: op)
            await cache.put(r2, key: key2, for: op)
            #expect(await store.contentCount() == 2)

            await cache.evict(keys: [key1])

            #expect(!(await cache.has(key: key1)))
            #expect(await cache.has(key: key2))
            #expect(await store.contentCount() == 1)
        }
    }

    @Test func statisticsReflectEntries() async throws {
        try await withCacheTestEnvironment { env in
            let (cache, _) = try await makeCache(tempDir: env.tempDir)

            let op = TestDataFactory.createOperation()
            let k1 = TestDataFactory.createCacheKey(operation: op, inputContents: ["a"], platform: .linuxAMD64)
            let k2 = TestDataFactory.createCacheKey(operation: op, inputContents: ["b"], platform: .linuxAMD64)
            let r = TestDataFactory.createCachedResult()

            await cache.put(r, key: k1, for: op)
            await cache.put(r, key: k2, for: op)

            _ = await cache.get(k1, for: op)  // one hit
            _ = await cache.get(k2, for: op)  // another hit
            _ = await cache.get(TestDataFactory.createCacheKey(operation: op, inputContents: ["c"], platform: .linuxAMD64), for: op)  // miss

            let stats = await cache.statistics()
            #expect(stats.entryCount == 2)
            #expect(stats.totalSize > 0)
            #expect(stats.averageEntrySize > 0)
            #expect(stats.hitRate > 0)
            #expect(stats.evictionPolicy == "lru")
        }
    }

    @Test func ttlEvictionViaBackgroundGC() async throws {
        try await withCacheTestEnvironment { env in
            // Short TTL and GC interval to exercise background cleanup
            let (cache, _) = try await makeCache(tempDir: env.tempDir, ttl: 0.05, gcInterval: 0.02)

            let op = TestDataFactory.createOperation()
            let key = TestDataFactory.createCacheKey(operation: op, inputContents: ["exp"], platform: .linuxAMD64)
            let r = TestDataFactory.createCachedResult()
            await cache.put(r, key: key, for: op)

            #expect(await cache.has(key: key))
            // Wait long enough for TTL to expire and GC to run
            try await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
            #expect(!(await cache.has(key: key)))
        }
    }

    @Test func orphanedIndexEntryIsCleanedOnMiss() async throws {
        try await withCacheTestEnvironment { env in
            // Seed a valid entry, then corrupt the stored manifest to simulate orphan/invalid content
            let (cache, store) = try await makeCache(tempDir: env.tempDir)
            let index = try CacheIndex(path: env.tempDir.appendingPathComponent("index", isDirectory: true))

            let op = TestDataFactory.createOperation(kind: "run", content: "corrupt")
            let key = TestDataFactory.createCacheKey(operation: op, inputContents: ["x", "y"], platform: .linuxAMD64)
            let r = TestDataFactory.createCachedResult(snapshotContent: "S")
            await cache.put(r, key: key, for: op)

            // Find the stored index entry
            let entries = try await index.allEntries()
            #expect(entries.count == 1)
            let (_, entry) = try #require(entries.first)

            // Overwrite manifest content with an invalid one (missing snapshot)
            let bad = CacheManifest(
                config: CacheConfig(
                    cacheKey: SerializedCacheKey(from: key),
                    operationType: String(describing: type(of: op)),
                    platform: key.platform,
                    buildVersion: "1.0"
                ),
                annotations: [:],
                subject: nil,
                snapshot: nil,  // <-- corrupt
                environmentChanges: [:],
                metadataChanges: [:]
            )
            try await store.put(bad, digest: entry.descriptor.digest)

            // Now a get should fail and effectively behave like a miss
            let got = await cache.get(key, for: op)
            #expect(got == nil)
        }
    }
}
