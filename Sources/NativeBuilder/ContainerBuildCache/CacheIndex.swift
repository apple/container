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
import ContainerizationExtras
import ContainerizationOCI
import Foundation

// MARK: - Cache Index

/// Actor-based cache index that manages cache metadata with atomic updates
public actor CacheIndex: Sendable {
    private let path: URL

    /// Cache index state persisted to cache.json
    struct State: Codable {
        var entries: [String: CacheEntry]
        var version: Int
        var statistics: Statistics

        struct Statistics: Codable {
            var totalSize: UInt64
            var entryCount: Int
            var hitCount: Int64
            var missCount: Int64
            var evictionCount: Int64
            var lastModified: Date
            var lastGC: Date?
        }

        static let empty = State(
            entries: [:],
            version: 1,
            statistics: Statistics(
                totalSize: 0,
                entryCount: 0,
                hitCount: 0,
                missCount: 0,
                evictionCount: 0,
                lastModified: Date(),
                lastGC: nil
            )
        )
    }

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        self.path = path
    }

    // MARK: - Public Methods

    /// Add or update a cache entry
    public func put(
        key: String,
        descriptor: Descriptor,
        metadata: CacheMetadata
    ) async throws {
        var state = try self.load()

        // Update or create entry
        let entry = CacheEntry(
            descriptor: descriptor,
            metadata: metadata
        )

        // Update statistics
        if state.entries[key] == nil {
            state.statistics.entryCount += 1
        }
        state.entries[key] = entry
        state.statistics.totalSize = calculateTotalSize(state.entries)
        state.statistics.lastModified = Date()

        try self.save(state)
    }

    /// Get a cache entry and update access time
    public func get(key: String) async throws -> CacheEntry? {
        var state = try self.load()

        guard var entry = state.entries[key] else {
            state.statistics.missCount += 1
            try self.save(state)
            return nil
        }

        // Update access time
        entry.metadata.accessedAt = Date()
        state.entries[key] = entry
        state.statistics.hitCount += 1
        state.statistics.lastModified = Date()

        try self.save(state)
        return entry
    }

    /// Remove cache entries
    public func remove(keys: [String]) async throws {
        var state = try self.load()

        for key in keys {
            if state.entries.removeValue(forKey: key) != nil {
                state.statistics.entryCount -= 1
                state.statistics.evictionCount += 1
            }
        }

        state.statistics.totalSize = calculateTotalSize(state.entries)
        state.statistics.lastModified = Date()

        try self.save(state)
    }

    /// Get all cache entries
    public func allEntries() async throws -> [String: CacheEntry] {
        let state = try self.load()
        return state.entries
    }

    /// Get cache statistics
    public func statistics() async throws -> CacheStatistics {
        let state = try self.load()

        // Calculate derived statistics
        let hitRate =
            state.statistics.hitCount + state.statistics.missCount > 0
            ? Double(state.statistics.hitCount) / Double(state.statistics.hitCount + state.statistics.missCount)
            : 0.0

        let ages = state.entries.values.map { entry in
            Date().timeIntervalSince(entry.metadata.createdAt)
        }.sorted()

        let oldestAge = ages.last ?? 0
        let newestAge = ages.first ?? 0

        let avgSize =
            state.statistics.entryCount > 0
            ? state.statistics.totalSize / UInt64(state.statistics.entryCount)
            : 0

        return CacheStatistics(
            entryCount: state.statistics.entryCount,
            totalSize: state.statistics.totalSize,
            hitRate: hitRate,
            oldestEntryAge: oldestAge,
            mostRecentEntryAge: newestAge,
            evictionPolicy: "lru",
            averageEntrySize: avgSize,
            operationMetrics: .empty,
            errorCount: 0,
            lastGCTime: state.statistics.lastGC,
            shardInfo: nil
        )
    }

    // MARK: - File Operations

    /// Load cache index from cache.json
    private func load() throws -> State {
        let indexPath = self.path.appendingPathComponent("cache.json")

        guard FileManager.default.fileExists(atPath: indexPath.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: indexPath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(State.self, from: data)
        } catch {
            // Handle corrupted index by starting fresh
            print("Warning: Cache index corrupted, starting with empty cache: \(error.localizedDescription)")

            // Try to backup the corrupted file for debugging
            let backupPath = indexPath.appendingPathExtension("corrupted")
            try? FileManager.default.moveItem(at: indexPath, to: backupPath)

            // Return empty state to start fresh
            return .empty
        }
    }

    /// Save cache index to cache.json atomically
    private func save(_ state: State) throws {
        let indexPath = self.path.appendingPathComponent("cache.json")
        let tempPath = indexPath.appendingPathExtension("tmp")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(state)
            try data.write(to: tempPath, options: .atomic)

            // Atomic rename
            _ = try FileManager.default.replaceItem(at: indexPath, withItemAt: tempPath, backupItemName: nil, options: [], resultingItemURL: nil)
        } catch {
            // Clean up temp file if it exists
            try? FileManager.default.removeItem(at: tempPath)
            throw CacheError.storageFailed(path: tempPath.path, underlyingError: error)
        }
    }

    // MARK: - Helper Methods

    private func calculateTotalSize(_ entries: [String: CacheEntry]) -> UInt64 {
        entries.values.reduce(0) { total, entry in
            total + UInt64(entry.descriptor.size)
        }
    }
}

// MARK: - Cache Entry

/// Individual cache entry containing manifest descriptor and metadata
public struct CacheEntry: Codable, Sendable {
    /// OCI descriptor for the cache manifest
    public let descriptor: Descriptor

    /// Cache metadata
    public var metadata: CacheMetadata

    public init(descriptor: Descriptor, metadata: CacheMetadata) {
        self.descriptor = descriptor
        self.metadata = metadata
    }
}

// MARK: - Cache Metadata

/// Metadata associated with a cache entry
public struct CacheMetadata: Codable, Sendable {
    /// When the entry was created
    public let createdAt: Date

    /// When the entry was last accessed
    public var accessedAt: Date

    /// Hash of the operation that created this cache entry
    public let operationHash: String

    /// Platform this cache entry is for
    public let platform: Platform

    /// Time-to-live in seconds (nil means no expiration)
    public let ttl: TimeInterval?

    /// Custom tags for filtering
    public let tags: [String: String]

    public init(
        createdAt: Date = Date(),
        accessedAt: Date = Date(),
        operationHash: String,
        platform: Platform,
        ttl: TimeInterval? = nil,
        tags: [String: String] = [:]
    ) {
        self.createdAt = createdAt
        self.accessedAt = accessedAt
        self.operationHash = operationHash
        self.platform = platform
        self.ttl = ttl
        self.tags = tags
    }

    /// Check if the entry has expired
    public var isExpired: Bool {
        guard let ttl = ttl else { return false }
        return Date().timeIntervalSince(createdAt) > ttl
    }
}
