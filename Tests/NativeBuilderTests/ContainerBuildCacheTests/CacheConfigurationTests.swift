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

@testable import ContainerBuildCache

struct CacheConfigurationTests {

    // MARK: - CacheConfiguration Tests

    @Test func cacheConfigurationDefaultValues() throws {
        let config = CacheConfiguration()

        #expect(config.maxSize == 10 * 1024 * 1024 * 1024)  // 10GB
        #expect(config.maxAge == 7 * 24 * 60 * 60)  // 7 days
        #expect(config.evictionPolicy == .lru)
        #expect(config.compression.algorithm == .zstd)
        #expect(config.compression.level == 3)
        #expect(config.compression.minSize == 1024)
        #expect(config.verifyIntegrity == true)
        #expect(config.sharding == nil)
        #expect(config.gcInterval == 3600)  // 1 hour
        #expect(config.cacheKeyVersion == "v1")
        #expect(config.defaultTTL == nil)
    }

    @Test func cacheConfigurationCustomValues() throws {
        let customIndexPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-cache.db")

        let customCompression = CompressionConfiguration(
            algorithm: .gzip,
            level: 6,
            minSize: 2048
        )

        let customConcurrency = ConcurrencyConfiguration(
            maxConcurrentReads: 50,
            maxConcurrentWrites: 5,
            maxConcurrentEvictions: 1
        )

        let config = CacheConfiguration(
            maxSize: 5 * 1024 * 1024 * 1024,  // 5GB
            maxAge: 3 * 24 * 60 * 60,  // 3 days
            compression: customCompression,
            indexPath: customIndexPath,
            evictionPolicy: .fifo,
            concurrency: customConcurrency,
            verifyIntegrity: false,
            sharding: nil,
            gcInterval: 1800,  // 30 minutes
            cacheKeyVersion: "v2",
            defaultTTL: 86400  // 1 day
        )

        #expect(config.maxSize == 5 * 1024 * 1024 * 1024)
        #expect(config.maxAge == 3 * 24 * 60 * 60)
        #expect(config.compression.algorithm == .gzip)
        #expect(config.compression.level == 6)
        #expect(config.compression.minSize == 2048)
        #expect(config.indexPath == customIndexPath)
        #expect(config.evictionPolicy == .fifo)
        #expect(config.concurrency.maxConcurrentReads == 50)
        #expect(config.concurrency.maxConcurrentWrites == 5)
        #expect(config.concurrency.maxConcurrentEvictions == 1)
        #expect(config.verifyIntegrity == false)
        #expect(config.sharding == nil)
        #expect(config.gcInterval == 1800)
        #expect(config.cacheKeyVersion == "v2")
        #expect(config.defaultTTL == 86400)
    }

    @Test func cacheConfigurationValidationLimits() throws {
        // Test that configuration accepts reasonable limits
        let config = CacheConfiguration(
            maxSize: 1024,  // 1KB minimum
            maxAge: 60,  // 1 minute minimum
            gcInterval: 30  // 30 seconds minimum
        )

        #expect(config.maxSize == 1024)
        #expect(config.maxAge == 60)
        #expect(config.gcInterval == 30)
    }

    // MARK: - EvictionPolicy Tests

    @Test func evictionPolicyLRU() throws {
        let policy = EvictionPolicy.lru
        #expect(policy == .lru)

        // Test that LRU is the default
        let config = CacheConfiguration()
        #expect(config.evictionPolicy == .lru)
    }

    @Test func evictionPolicyFIFO() throws {
        let policy = EvictionPolicy.fifo
        #expect(policy == .fifo)

        let config = CacheConfiguration(evictionPolicy: .fifo)
        #expect(config.evictionPolicy == .fifo)
    }

    @Test func evictionPolicyARC() throws {
        let policy = EvictionPolicy.arc
        #expect(policy == .arc)

        let config = CacheConfiguration(evictionPolicy: .arc)
        #expect(config.evictionPolicy == .arc)
    }

    // MARK: - CompressionConfiguration Tests

    @Test func compressionConfigurationDefault() throws {
        let compression = CompressionConfiguration.default

        #expect(compression.algorithm == .zstd)
        #expect(compression.level == 3)
        #expect(compression.minSize == 1024)
    }

    @Test func compressionConfigurationCustomAlgorithms() throws {
        let zstdConfig = CompressionConfiguration(algorithm: .zstd, level: 5, minSize: 512)
        #expect(zstdConfig.algorithm == .zstd)
        #expect(zstdConfig.level == 5)
        #expect(zstdConfig.minSize == 512)

        let lz4Config = CompressionConfiguration(algorithm: .lz4, level: 1, minSize: 256)
        #expect(lz4Config.algorithm == .lz4)
        #expect(lz4Config.level == 1)
        #expect(lz4Config.minSize == 256)

        let gzipConfig = CompressionConfiguration(algorithm: .gzip, level: 9, minSize: 2048)
        #expect(gzipConfig.algorithm == .gzip)
        #expect(gzipConfig.level == 9)
        #expect(gzipConfig.minSize == 2048)

        let noneConfig = CompressionConfiguration(algorithm: .none, level: 0, minSize: 0)
        #expect(noneConfig.algorithm == .none)
        #expect(noneConfig.level == 0)
        #expect(noneConfig.minSize == 0)
    }

    @Test func compressionConfigurationAlgorithmRawValues() throws {
        #expect(CompressionConfiguration.CompressionAlgorithm.zstd.rawValue == "zstd")
        #expect(CompressionConfiguration.CompressionAlgorithm.lz4.rawValue == "lz4")
        #expect(CompressionConfiguration.CompressionAlgorithm.gzip.rawValue == "gzip")
        #expect(CompressionConfiguration.CompressionAlgorithm.none.rawValue == "none")
    }

    // MARK: - ConcurrencyConfiguration Tests

    @Test func concurrencyConfigurationDefault() throws {
        let concurrency = ConcurrencyConfiguration.default

        #expect(concurrency.maxConcurrentReads == 100)
        #expect(concurrency.maxConcurrentWrites == 10)
        #expect(concurrency.maxConcurrentEvictions == 2)
    }

    @Test func concurrencyConfigurationCustom() throws {
        let concurrency = ConcurrencyConfiguration(
            maxConcurrentReads: 200,
            maxConcurrentWrites: 20,
            maxConcurrentEvictions: 5
        )

        #expect(concurrency.maxConcurrentReads == 200)
        #expect(concurrency.maxConcurrentWrites == 20)
        #expect(concurrency.maxConcurrentEvictions == 5)
    }

    @Test func concurrencyConfigurationMinimalValues() throws {
        let concurrency = ConcurrencyConfiguration(
            maxConcurrentReads: 1,
            maxConcurrentWrites: 1,
            maxConcurrentEvictions: 1
        )

        #expect(concurrency.maxConcurrentReads == 1)
        #expect(concurrency.maxConcurrentWrites == 1)
        #expect(concurrency.maxConcurrentEvictions == 1)
    }

    // MARK: - CacheStatistics Tests

    @Test func cacheStatisticsInitialization() throws {
        let operationMetrics = OperationMetrics(
            totalOperations: 100,
            averageGetDuration: 0.05,
            averagePutDuration: 0.1,
            p95GetDuration: 0.08,
            p95PutDuration: 0.15
        )
        let stats = CacheStatistics(
            entryCount: 100,
            totalSize: 1024 * 1024,
            hitRate: 0.85,
            oldestEntryAge: 3600,
            mostRecentEntryAge: 60,
            evictionPolicy: "lru",
            compressionRatio: 0.7,
            averageEntrySize: 10240,
            operationMetrics: operationMetrics,
            errorCount: 0,
            lastGCTime: nil,
            shardInfo: nil
        )

        #expect(stats.entryCount == 100)
        #expect(stats.totalSize == 1024 * 1024)
        #expect(abs(stats.hitRate - 0.85) < 0.001)
        #expect(stats.oldestEntryAge == 3600)
        #expect(stats.mostRecentEntryAge == 60)
    }

    @Test func cacheStatisticsEmptyCache() throws {
        let operationMetrics = OperationMetrics(
            totalOperations: 0,
            averageGetDuration: 0.0,
            averagePutDuration: 0.0,
            p95GetDuration: 0.0,
            p95PutDuration: 0.0
        )
        let stats = CacheStatistics(
            entryCount: 0,
            totalSize: 0,
            hitRate: 0.0,
            oldestEntryAge: 0,
            mostRecentEntryAge: 0,
            evictionPolicy: "lru",
            compressionRatio: 1.0,
            averageEntrySize: 0,
            operationMetrics: operationMetrics,
            errorCount: 0,
            lastGCTime: nil,
            shardInfo: nil
        )

        #expect(stats.entryCount == 0)
        #expect(stats.totalSize == 0)
        #expect(stats.hitRate == 0.0)
        #expect(stats.oldestEntryAge == 0)
        #expect(stats.mostRecentEntryAge == 0)
    }

    // MARK: - Integration Tests

    @Test func cacheConfigurationIntegration() throws {
        // Test that all configuration components work together
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        let config = CacheConfiguration(
            maxSize: 512 * 1024 * 1024,  // 512MB
            maxAge: 24 * 60 * 60,  // 1 day
            compression: CompressionConfiguration(algorithm: .lz4, level: 1, minSize: 512),
            indexPath: tempDir.appendingPathComponent("test-cache.db"),
            evictionPolicy: .lru,
            concurrency: ConcurrencyConfiguration(
                maxConcurrentReads: 50,
                maxConcurrentWrites: 5,
                maxConcurrentEvictions: 1
            ),
            verifyIntegrity: true,
            sharding: nil,
            gcInterval: 900,  // 15 minutes
            cacheKeyVersion: "test-v1",
            defaultTTL: 7200  // 2 hours
        )

        // Verify all settings are preserved
        #expect(config.maxSize == 512 * 1024 * 1024)
        #expect(config.maxAge == 24 * 60 * 60)
        #expect(config.compression.algorithm == .lz4)
        #expect(config.compression.level == 1)
        #expect(config.compression.minSize == 512)
        #expect(config.evictionPolicy == .lru)
        #expect(config.concurrency.maxConcurrentReads == 50)
        #expect(config.concurrency.maxConcurrentWrites == 5)
        #expect(config.concurrency.maxConcurrentEvictions == 1)
        #expect(config.verifyIntegrity == true)
        #expect(config.sharding == nil)
        #expect(config.gcInterval == 900)
        #expect(config.cacheKeyVersion == "test-v1")
        #expect(config.defaultTTL == 7200)
    }

    // MARK: - Edge Cases

    @Test func cacheConfigurationEdgeCases() throws {
        // Test with very large values
        let largeConfig = CacheConfiguration(
            maxSize: UInt64.max,
            maxAge: TimeInterval.greatestFiniteMagnitude,
            gcInterval: TimeInterval.greatestFiniteMagnitude
        )

        #expect(largeConfig.maxSize == UInt64.max)
        #expect(largeConfig.maxAge == TimeInterval.greatestFiniteMagnitude)
        #expect(largeConfig.gcInterval == TimeInterval.greatestFiniteMagnitude)

        // Test with minimal values
        let minimalConfig = CacheConfiguration(
            maxSize: 0,
            maxAge: 0,
            gcInterval: 0
        )

        #expect(minimalConfig.maxSize == 0)
        #expect(minimalConfig.maxAge == 0)
        #expect(minimalConfig.gcInterval == 0)
    }
}
