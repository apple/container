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

// MARK: - Configuration Types

/// Cache configuration
public struct CacheConfiguration: Sendable {
    /// Maximum cache size in bytes
    public let maxSize: UInt64

    /// Maximum age for cache entries
    public let maxAge: TimeInterval

    /// Compression configuration
    public let compression: CompressionConfiguration

    /// Index database path
    public let indexPath: URL

    /// Eviction policy
    public let evictionPolicy: EvictionPolicy

    /// Concurrency limits
    public let concurrency: ConcurrencyConfiguration

    /// Integrity verification
    public let verifyIntegrity: Bool

    /// Shard configuration for distributed caching
    public let sharding: ShardingConfiguration?

    /// Garbage collection interval
    public let gcInterval: TimeInterval

    /// Cache key version for invalidation
    public let cacheKeyVersion: String

    /// Default TTL for cache entries
    public let defaultTTL: TimeInterval?

    public init(
        maxSize: UInt64 = 10 * 1024 * 1024 * 1024,  // 10GB default
        maxAge: TimeInterval = 7 * 24 * 60 * 60,  // 7 days default
        compression: CompressionConfiguration = .default,
        indexPath: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.apple.container-build.cache.db"),
        evictionPolicy: EvictionPolicy = .lru,
        concurrency: ConcurrencyConfiguration = .default,
        verifyIntegrity: Bool = true,
        sharding: ShardingConfiguration? = nil,
        gcInterval: TimeInterval = 3600,  // 1 hour
        cacheKeyVersion: String = "v1",
        defaultTTL: TimeInterval? = nil
    ) {
        self.maxSize = maxSize
        self.maxAge = maxAge
        self.compression = compression
        self.indexPath = indexPath
        self.evictionPolicy = evictionPolicy
        self.concurrency = concurrency
        self.verifyIntegrity = verifyIntegrity
        self.sharding = sharding
        self.gcInterval = gcInterval
        self.cacheKeyVersion = cacheKeyVersion
        self.defaultTTL = defaultTTL
    }
}

public struct CompressionConfiguration: Sendable {
    public let algorithm: CompressionAlgorithm
    public let level: Int
    public let minSize: Int  // Minimum size to compress

    public enum CompressionAlgorithm: String, Sendable {
        case zstd = "zstd"
        case lz4 = "lz4"
        case gzip = "gzip"
        case none = "none"
    }

    public static let `default` = CompressionConfiguration(
        algorithm: .zstd,
        level: 3,
        minSize: 1024  // 1KB
    )

    public init(algorithm: CompressionAlgorithm, level: Int, minSize: Int) {
        self.algorithm = algorithm
        self.level = level
        self.minSize = minSize
    }
}

public enum EvictionPolicy: String, Sendable {
    case lru = "lru"  // Least Recently Used
    case lfu = "lfu"  // Least Frequently Used
    case fifo = "fifo"  // First In First Out
    case ttl = "ttl"  // Time To Live based
    case arc = "arc"  // Adaptive Replacement Cache
}

public struct ConcurrencyConfiguration: Sendable {
    public let maxConcurrentReads: Int
    public let maxConcurrentWrites: Int
    public let maxConcurrentEvictions: Int

    public static let `default` = ConcurrencyConfiguration(
        maxConcurrentReads: 100,
        maxConcurrentWrites: 10,
        maxConcurrentEvictions: 2
    )

    public init(maxConcurrentReads: Int, maxConcurrentWrites: Int, maxConcurrentEvictions: Int) {
        self.maxConcurrentReads = maxConcurrentReads
        self.maxConcurrentWrites = maxConcurrentWrites
        self.maxConcurrentEvictions = maxConcurrentEvictions
    }
}

public struct ShardingConfiguration: Sendable {
    public let shardCount: Int
    public let shardId: Int
    public let consistentHashing: Bool

    public init(shardCount: Int, shardId: Int, consistentHashing: Bool = true) {
        self.shardCount = shardCount
        self.shardId = shardId
        self.consistentHashing = consistentHashing
    }
}

// MARK: - Cache Entry Types

/// Cache index entry for tracking
struct CacheIndexEntry: Sendable, Codable {
    let digest: String
    let manifestSize: Int64
    let totalSize: UInt64
    let createdAt: Date
    var lastAccessedAt: Date
    var accessCount: Int64
    let platform: Platform
    let operationType: String
    let contentDigests: [String]
    let compression: String
    let transaction: UUID?

    var age: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }
}

/// Normalized platform for consistent hashing
struct NormalizedPlatform: Codable {
    let os: String
    let architecture: String
    let variant: String?
    let osVersion: String?
    let osFeatures: [String]?
}

// MARK: - Statistics Types

/// Enhanced cache statistics
public struct CacheStatistics: Sendable {
    public let entryCount: Int
    public let totalSize: UInt64
    public let hitRate: Double
    public let oldestEntryAge: TimeInterval
    public let mostRecentEntryAge: TimeInterval
    public let evictionPolicy: String
    public let compressionRatio: Double
    public let averageEntrySize: UInt64
    public let operationMetrics: OperationMetrics
    public let errorCount: Int
    public let lastGCTime: Date?
    public let shardInfo: ShardInfo?

    public static let empty = CacheStatistics(
        entryCount: 0,
        totalSize: 0,
        hitRate: 0,
        oldestEntryAge: 0,
        mostRecentEntryAge: 0,
        evictionPolicy: "none",
        compressionRatio: 1.0,
        averageEntrySize: 0,
        operationMetrics: .empty,
        errorCount: 0,
        lastGCTime: nil,
        shardInfo: nil
    )
}

public struct OperationMetrics: Sendable {
    public let totalOperations: Int64
    public let averageGetDuration: TimeInterval
    public let averagePutDuration: TimeInterval
    public let p95GetDuration: TimeInterval
    public let p95PutDuration: TimeInterval

    public static let empty = OperationMetrics(
        totalOperations: 0,
        averageGetDuration: 0,
        averagePutDuration: 0,
        p95GetDuration: 0,
        p95PutDuration: 0
    )
}

public struct ShardInfo: Sendable {
    public let shardId: Int
    public let totalShards: Int
}

// MARK: - Operation Types

/// Clear filter for selective cache clearing
public struct ClearFilter: Sendable {
    public let platform: Platform?
    public let operationType: String?
    public let olderThan: Date?
    public let pattern: String?

    public init(
        platform: Platform? = nil,
        operationType: String? = nil,
        olderThan: Date? = nil,
        pattern: String? = nil
    ) {
        self.platform = platform
        self.operationType = operationType
        self.olderThan = olderThan
        self.pattern = pattern
    }
}

// MARK: - Eviction Types

enum EvictionReason: String {
    case sizeLimit = "size_limit"
    case expired = "expired"
    case manual = "manual"
    case lowMemory = "low_memory"
}

// MARK: - Extensions

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension ContainerBuildIR.Digest {
    func hexEncodedString() -> String {
        self.bytes.map { String(format: "%02x", $0) }.joined()
    }
}
