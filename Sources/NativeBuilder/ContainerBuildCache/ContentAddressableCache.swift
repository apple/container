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
import Crypto
import Foundation

/// Content-addressable cache implementation using ContentStore as backing storage.
///
/// This implementation stores cache entries as OCI artifacts with manifests
/// pointing to content layers. It provides atomic operations, deduplication,
/// and efficient eviction policies.
public actor ContentAddressableCache: BuildCache {
    private let contentStore: ContentStore
    private let index: CacheIndex
    private let configuration: CacheConfiguration
    private var evictionTask: Task<Void, Never>?

    /// Initialize a new content-addressable cache.
    ///
    /// - Parameters:
    ///   - contentStore: The content store for storage
    ///   - configuration: Cache configuration
    public init(
        contentStore: ContentStore,
        configuration: CacheConfiguration = CacheConfiguration()
    ) async throws {
        self.contentStore = contentStore
        self.configuration = configuration
        do {
            self.index = try CacheIndex(path: configuration.indexPath)
        } catch {
            throw CacheError.manifestUnreadable(path: configuration.indexPath.path, underlyingError: error)
        }

        // Start background eviction task
        self.evictionTask = Task { [weak self] in
            await self?.runPeriodicEviction()
        }
    }

    deinit {
        evictionTask?.cancel()
    }

    // MARK: - BuildCache Protocol Implementation

    public func get(_ key: CacheKey, for operation: ContainerBuildIR.Operation) async -> CachedResult? {
        // Generate cache digest
        guard let digest = try? generateCacheDigest(from: key) else {
            return nil
        }

        // Check index
        guard let entry = try? await index.get(key: digest) else {
            return nil
        }

        // Fetch manifest from content store using the manifest digest from the index
        guard let manifest: CacheManifest = try? await contentStore.get(digest: entry.descriptor.digest) else {
            // Clean up orphaned index entry
            try? await index.remove(keys: [digest])
            return nil
        }

        // Reconstruct result from manifest
        guard let result = try? await reconstructResult(from: manifest) else {
            return nil
        }

        // Update access time
        var updatedMetadata = entry.metadata
        updatedMetadata.accessedAt = Date()
        try? await index.put(key: digest, descriptor: entry.descriptor, metadata: updatedMetadata)

        return result
    }

    public func put(_ result: CachedResult, key: CacheKey, for operation: ContainerBuildIR.Operation) async {
        // Generate cache digest
        guard let digest = try? generateCacheDigest(from: key) else {
            return
        }

        // Check if already exists
        if let _ = try? await index.get(key: digest) {
            return
        }

        do {
            // Start new ingest session
            let (sessionId, ingestDir) = try await contentStore.newIngestSession()

            do {
                // Create content writer for this session
                let writer = try ContentWriter(for: ingestDir)

                // Store components
                let snapshotLayer = try await storeSnapshot(result.snapshot, using: writer)
                let environmentLayer = try await storeEnvironment(result.environmentChanges, using: writer)
                let metadataLayer = try await storeMetadata(result.metadataChanges, using: writer)

                // Create manifest
                let manifest = createManifest(
                    key: key,
                    operation: operation,
                    layers: [snapshotLayer, environmentLayer, metadataLayer].compactMap { $0 }
                )

                // Write manifest
                let (manifestSize, manifestDigest) = try writer.create(from: manifest)

                // Complete ingest session
                _ = try await contentStore.completeIngestSession(sessionId)

                // Calculate total size
                let _ =
                    manifestSize
                    + [snapshotLayer, environmentLayer, metadataLayer]
                    .compactMap { $0 }
                    .reduce(0) { $0 + $1.descriptor.size }

                // Record in index
                let descriptor = Descriptor(
                    mediaType: manifest.mediaType,
                    digest: manifestDigest.digestString,
                    size: manifestSize
                )

                let operationHash: String
                do {
                    operationHash = try operation.contentDigest().stringValue
                } catch {
                    // If we can't compute the operation hash, use a fallback
                    operationHash = "unknown"
                }

                let metadata = CacheMetadata(
                    createdAt: Date(),
                    accessedAt: Date(),
                    operationHash: operationHash,
                    platform: key.platform,
                    ttl: configuration.defaultTTL,
                    tags: [:]
                )

                try await index.put(key: digest, descriptor: descriptor, metadata: metadata)

                // Trigger eviction if needed
                Task { [weak self] in
                    await self?.checkAndEvict()
                }

            } catch {
                // Cancel ingest session on error
                try? await contentStore.cancelIngestSession(sessionId)
                throw error
            }
        } catch {
            // Log error but don't propagate - caching should not fail builds
            print("Cache put failed: \(error)")
        }
    }

    public func has(key: CacheKey) async -> Bool {
        guard let digest = try? generateCacheDigest(from: key) else {
            return false
        }
        return (try? await index.get(key: digest)) != nil
    }

    public func evict(keys: [CacheKey]) async {
        for key in keys {
            guard let digest = try? generateCacheDigest(from: key) else {
                continue
            }

            if let entry = try? await index.get(key: digest) {
                // Get manifest to find content digests
                if let manifest: CacheManifest = try? await contentStore.get(digest: entry.descriptor.digest) {
                    let digests = [entry.descriptor.digest] + manifest.allContentDigests()
                    _ = try? await contentStore.delete(digests: digests)
                }

                // Remove from index
                try? await index.remove(keys: [digest])
            }
        }
    }

    public func statistics() async -> CacheStatistics {
        let stats = (try? await index.statistics()) ?? CacheStatistics.empty

        return CacheStatistics(
            entryCount: stats.entryCount,
            totalSize: stats.totalSize,
            hitRate: stats.hitRate,
            oldestEntryAge: stats.oldestEntryAge,
            mostRecentEntryAge: stats.mostRecentEntryAge,
            evictionPolicy: "lru",
            compressionRatio: 1.0,
            averageEntrySize: stats.entryCount > 0 ? stats.totalSize / UInt64(stats.entryCount) : 0,
            operationMetrics: .empty,
            errorCount: 0,
            lastGCTime: nil,
            shardInfo: nil
        )
    }

    // MARK: - Private Methods

    /// Generate a deterministic cache digest from the cache key.
    /// - Throws: CacheError.encodingFailed if UTF-8 encoding fails
    private func generateCacheDigest(from key: CacheKey) throws -> String {
        var hasher = SHA256()

        // Version prefix for cache invalidation
        guard let versionData = configuration.cacheKeyVersion.data(using: .utf8) else {
            // This should never happen as cacheKeyVersion is controlled internally
            throw CacheError.encodingFailed("Failed to encode cache key version as UTF-8: \(configuration.cacheKeyVersion)")
        }
        hasher.update(data: versionData)

        // Operation digest
        hasher.update(data: key.operationDigest.bytes)

        // Sorted input digests for determinism
        for digest in key.inputDigests.sorted(by: { $0.stringValue < $1.stringValue }) {
            hasher.update(data: digest.bytes)
        }

        // Platform data
        let platformData = encodePlatform(key.platform)
        hasher.update(data: platformData)

        let digest = hasher.finalize()
        let hexString = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hexString)"
    }

    /// Encode platform to canonical form for hashing.
    private func encodePlatform(_ platform: Platform) -> Data {
        let normalized = NormalizedPlatform(
            os: platform.os,
            architecture: platform.architecture,
            variant: platform.variant,
            osVersion: platform.osVersion,
            osFeatures: platform.osFeatures?.sorted()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(normalized)) ?? Data()
    }

    /// Store snapshot data and return layer descriptor.
    private func storeSnapshot(_ snapshot: Snapshot, using writer: ContentWriter) async throws -> CacheLayer? {
        let data = try JSONEncoder().encode(snapshot)
        let compressed = try compress(data)
        let (size, digest) = try writer.write(compressed)

        let descriptor = Descriptor.forCacheContent(
            mediaType: "application/vnd.container-build.snapshot.v1+json",
            digest: digest.digestString,
            size: size,
            compressed: true,
            annotations: [
                "com.apple.container-build.compression": configuration.compression.algorithm.rawValue,
                "com.apple.container-build.uncompressed-size": String(data.count),
            ]
        )

        return CacheLayer(descriptor: descriptor, type: .snapshot)
    }

    /// Store environment changes and return layer descriptor.
    private func storeEnvironment(_ changes: [String: EnvironmentValue], using writer: ContentWriter) async throws -> CacheLayer? {
        guard !changes.isEmpty else { return nil }

        let data = try JSONEncoder().encode(changes)
        let compressed = try compress(data)
        let (size, digest) = try writer.write(compressed)

        let descriptor = Descriptor.forCacheContent(
            mediaType: "application/vnd.container-build.environment.v1+json",
            digest: digest.digestString,
            size: size,
            compressed: true,
            annotations: [
                "com.apple.container-build.compression": configuration.compression.algorithm.rawValue
            ]
        )

        return CacheLayer(descriptor: descriptor, type: .environment)
    }

    /// Store metadata changes and return layer descriptor.
    private func storeMetadata(_ changes: [String: String], using writer: ContentWriter) async throws -> CacheLayer? {
        guard !changes.isEmpty else { return nil }

        let data = try JSONEncoder().encode(changes)
        let compressed = try compress(data)
        let (size, digest) = try writer.write(compressed)

        let descriptor = Descriptor.forCacheContent(
            mediaType: "application/vnd.container-build.metadata.v1+json",
            digest: digest.digestString,
            size: size,
            compressed: true,
            annotations: [
                "com.apple.container-build.compression": configuration.compression.algorithm.rawValue
            ]
        )

        return CacheLayer(descriptor: descriptor, type: .metadata)
    }

    /// Create cache manifest.
    private func createManifest(key: CacheKey, operation: ContainerBuildIR.Operation, layers: [CacheLayer]) -> CacheManifest {
        CacheManifest(
            schemaVersion: 2,
            mediaType: CacheManifest.manifestMediaType,
            config: CacheConfig(
                cacheKey: SerializedCacheKey(from: key),
                operationType: String(describing: type(of: operation)),
                platform: key.platform,
                buildVersion: "1.0.0"
            ),
            layers: layers,
            annotations: [
                "com.apple.container-build.created": ISO8601DateFormatter().string(from: Date()),
                "com.apple.container-build.cache-version": configuration.cacheKeyVersion,
            ],
            subject: nil
        )
    }

    /// Reconstruct cached result from manifest.
    private func reconstructResult(from manifest: CacheManifest) async throws -> CachedResult {
        var snapshot: Snapshot?
        var environmentChanges: [String: EnvironmentValue] = [:]
        var metadataChanges: [String: String] = [:]

        for layer in manifest.layers {
            guard let content = try await contentStore.get(digest: layer.descriptor.digest) else {
                throw CacheError.storageFailed(
                    path: layer.descriptor.digest, underlyingError: NSError(domain: "Cache", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing content"]))
            }

            let data = try content.data()
            let decompressed = try decompress(data)

            switch layer.type {
            case .snapshot:
                snapshot = try JSONDecoder().decode(Snapshot.self, from: decompressed)
            case .environment:
                environmentChanges = try JSONDecoder().decode([String: EnvironmentValue].self, from: decompressed)
            case .metadata:
                metadataChanges = try JSONDecoder().decode([String: String].self, from: decompressed)
            }
        }

        guard let snapshot = snapshot else {
            throw CacheError.storageFailed(
                path: "Missing snapshot layer", underlyingError: NSError(domain: "Cache", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid Manifest"]))
        }

        return CachedResult(
            snapshot: snapshot,
            environmentChanges: environmentChanges,
            metadataChanges: metadataChanges
        )
    }

    /// Compress data based on configuration.
    private func compress(_ data: Data) throws -> Data {
        guard data.count >= configuration.compression.minSize else {
            return data
        }

        switch configuration.compression.algorithm {
        case .none:
            return data
        case .zstd:
            // Use zstd compression (would need actual implementation)
            return data  // Placeholder
        case .lz4:
            // Use lz4 compression (would need actual implementation)
            return data  // Placeholder
        case .gzip:
            // Use gzip compression
            return try (data as NSData).compressed(using: .zlib) as Data
        }
    }

    /// Decompress data based on manifest metadata.
    private func decompress(_ data: Data) throws -> Data {
        // Check if data is compressed by trying to decompress
        if let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data {
            return decompressed
        }
        return data
    }

    /// Check if eviction is needed and trigger it.
    private func checkAndEvict() async {
        let stats = try? await index.statistics()

        guard let stats = stats else { return }

        // Check if we need to evict based on size
        if stats.totalSize > configuration.maxSize {
            await performEviction(targetSize: UInt64(Double(configuration.maxSize) * 0.8))
        }
    }

    /// Perform cache eviction to reach target size.
    private func performEviction(targetSize: UInt64) async {
        let stats = try? await index.statistics()
        guard let currentSize = stats?.totalSize, currentSize > targetSize else { return }

        let sizeToEvict = currentSize - targetSize

        // Get all entries and sort by access time (LRU)
        guard let allEntries = try? await index.allEntries() else { return }
        let sortedEntries = allEntries.sorted { $0.value.metadata.accessedAt < $1.value.metadata.accessedAt }

        var evictedSize: UInt64 = 0
        var keysToEvict: [String] = []
        var digestsToDelete: [String] = []

        for (key, entry) in sortedEntries {
            // Get manifest to find all content digests
            if let manifest: CacheManifest = try? await contentStore.get(digest: entry.descriptor.digest) {
                digestsToDelete.append(entry.descriptor.digest)
                digestsToDelete.append(contentsOf: manifest.allContentDigests())
            }

            keysToEvict.append(key)
            evictedSize += UInt64(entry.descriptor.size)

            if evictedSize >= sizeToEvict {
                break
            }
        }

        // Remove from index
        try? await index.remove(keys: keysToEvict)

        // Delete content from store
        _ = try? await contentStore.delete(digests: digestsToDelete)
    }

    /// Run periodic eviction task.
    private func runPeriodicEviction() async {
        while !Task.isCancelled {
            // Sleep for GC interval
            try? await Task.sleep(nanoseconds: UInt64(configuration.gcInterval * 1_000_000_000))

            // Remove expired entries based on TTL
            guard let allEntries = try? await index.allEntries() else { return }
            var keysToEvict: [String] = []
            var digestsToDelete: [String] = []

            for (key, entry) in allEntries {
                // Check TTL
                if let ttl = entry.metadata.ttl {
                    let expirationDate = entry.metadata.createdAt.addingTimeInterval(ttl)
                    if Date() > expirationDate {
                        keysToEvict.append(key)

                        // Get manifest to find all content digests
                        if let manifest: CacheManifest = try? await contentStore.get(digest: entry.descriptor.digest) {
                            digestsToDelete.append(entry.descriptor.digest)
                            digestsToDelete.append(contentsOf: manifest.allContentDigests())
                        }
                    }
                }
            }

            if !keysToEvict.isEmpty {
                try? await index.remove(keys: keysToEvict)
                _ = try? await contentStore.delete(digests: digestsToDelete)
            }

            // Check size limits
            await checkAndEvict()
        }
    }
}

// MARK: - Extensions

extension Platform {
    var canonicalString: String {
        var parts = ["\(os)/\(architecture)"]
        if let variant = variant {
            parts.append(variant)
        }
        return parts.joined(separator: "/")
    }

    /// - Throws: CacheError.encodingFailed if UTF-8 encoding fails
    func canonicalRepresentation() throws -> Data {
        guard let data = canonicalString.data(using: .utf8) else {
            // This should never happen as canonicalString contains only valid UTF-8
            throw CacheError.encodingFailed("Failed to encode canonical platform string as UTF-8: \(canonicalString)")
        }
        return data
    }
}
