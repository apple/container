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

/// Protocol for build cache implementations.
///
/// The cache stores operation results to avoid redundant execution.
///
/// PERFORMANCE OPTIMIZATION OPPORTUNITIES (from Design.md):
///
/// 1. Graph-Level Cache Analysis:
///    - Add a method to check multiple cache keys in parallel before execution starts
///    - Return a map of cache hits/misses for the entire build graph
///    - Example: func checkBatch(_ keys: [CacheKey]) async -> [CacheKey: Bool]
///
/// 2. Cache-Aware Graph Transformation:
///    - Implement a CachedScheduler that pre-processes the build graph
///    - Replace cached operations with lightweight cache retrieval operations
///    - Skip entire dependency chains if final results are cached
///
/// 3. Speculative Cache Warming:
///    - Add methods to prefetch likely cache entries based on build patterns
///    - Support background cache population for common operations
///
/// 4. Parallel Cache Operations:
///    - Batch get/put operations for multiple artifacts
///    - Use Swift concurrency for non-blocking cache access
///    - Example: func getBatch(_ keys: [CacheKey]) async -> [CacheKey: CachedResult?]
///
/// 5. Cache Metadata for Scheduling:
///    - Expose cache hit probability estimates
///    - Provide operation cost estimates based on historical data
///    - Enable scheduler to make smarter execution decisions
///
/// Current implementation is functionally correct but checks cache sequentially
/// during execution rather than optimizing the execution graph based on cache state.
public protocol BuildCache: Sendable {
    /// Look up a cached result for an operation.
    ///
    /// - Parameters:
    ///   - key: The cache key for the operation
    ///   - operation: The operation being cached
    /// - Returns: The cached result if found, nil otherwise
    func get(_ key: CacheKey, for operation: ContainerBuildIR.Operation) async -> CachedResult?

    /// Store a result in the cache.
    ///
    /// - Parameters:
    ///   - result: The result to cache
    ///   - key: The cache key
    ///   - operation: The operation that produced the result
    func put(_ result: CachedResult, key: CacheKey, for operation: ContainerBuildIR.Operation) async

    /// Get cache statistics.
    ///
    /// - Returns: Statistics about cache usage and performance
    func statistics() async -> CacheStatistics
}

/// A key for cache lookups.
public struct CacheKey: Hashable, Sendable {
    /// The digest of the operation.
    public let operationDigest: ContainerBuildIR.Digest

    /// Input digests from dependencies.
    public let inputDigests: [ContainerBuildIR.Digest]

    /// Platform identifier.
    public let platform: Platform

    public init(
        operationDigest: ContainerBuildIR.Digest,
        inputDigests: [ContainerBuildIR.Digest] = [],
        platform: Platform
    ) {
        self.operationDigest = operationDigest
        self.inputDigests = inputDigests
        self.platform = platform
    }
}

/// A cached execution result.
public struct CachedResult: Sendable {
    /// The snapshot produced by the operation.
    public let snapshot: Snapshot

    /// Environment changes made by the operation.
    public let environmentChanges: [String: EnvironmentValue]

    /// Metadata changes.
    public let metadataChanges: [String: String]

    public init(
        snapshot: Snapshot,
        environmentChanges: [String: EnvironmentValue] = [:],
        metadataChanges: [String: String] = [:]
    ) {
        self.snapshot = snapshot
        self.environmentChanges = environmentChanges
        self.metadataChanges = metadataChanges
    }
}

/// A no-op cache implementation that never caches.
public struct NoOpBuildCache: BuildCache {
    public init() {}

    public func get(_ key: CacheKey, for operation: ContainerBuildIR.Operation) async -> CachedResult? {
        nil
    }

    public func put(_ result: CachedResult, key: CacheKey, for operation: ContainerBuildIR.Operation) async {
        // No-op
    }

    public func statistics() async -> CacheStatistics {
        CacheStatistics(
            entryCount: 0,
            totalSize: 0,
            hitRate: 0,
            oldestEntryAge: 0,
            mostRecentEntryAge: 0,
            evictionPolicy: "none",
            averageEntrySize: 0,
            operationMetrics: .empty,
            errorCount: 0,
            lastGCTime: nil,
            shardInfo: nil
        )
    }
}
