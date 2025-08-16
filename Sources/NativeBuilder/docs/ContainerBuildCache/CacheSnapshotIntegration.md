# ContainerBuildCache Snapshot Integration

## Overview

The ContainerBuildCache subsystem provides a content-addressable caching layer that stores and retrieves snapshots to avoid redundant operation execution. The cache embeds snapshots directly in cache manifests, enabling efficient storage and retrieval of build artifacts.

## How Cache Uses Snapshots

### 1. Snapshot Storage in Cache Manifests

The [`CacheManifest`](../../ContainerBuildCache/CacheManifest.swift:30) embeds snapshots directly:

```swift
public struct CacheManifest {
    /// Snapshot embedded directly in manifest
    let snapshot: Snapshot?
    
    /// Environment changes from the operation
    let environmentChanges: [String: EnvironmentValue]
    
    /// Metadata changes
    let metadataChanges: [String: String]
}
```

Key characteristics:
- **Direct Embedding**: Snapshots are stored as part of the cache manifest (schema version 5)
- **Self-Contained**: No separate layer storage required - the manifest contains all necessary state
- **Atomic Operations**: Snapshot and metadata are stored/retrieved together

### 2. Cache Key Generation

The [`ContentAddressableCache`](../../ContainerBuildCache/ContentAddressableCache.swift:218) generates deterministic cache keys:

```swift
private func generateCacheDigest(from key: CacheKey) throws -> String {
    var hasher = SHA256()
    
    // Version prefix for cache invalidation
    hasher.update(data: cacheKeyVersion)
    
    // Operation digest
    hasher.update(data: key.operationDigest.bytes)
    
    // Sorted input digests (includes parent snapshot digests)
    for digest in key.inputDigests.sorted() {
        hasher.update(data: digest.bytes)
    }
    
    // Platform information
    hasher.update(data: encodePlatform(key.platform))
    
    return "sha256:\(hexString)"
}
```

This ensures:
- **Deterministic Keys**: Same inputs always produce the same cache key
- **Snapshot Lineage**: Parent snapshot digests are included in input digests
- **Platform Awareness**: Platform-specific builds are cached separately

### 3. Storing Snapshots (Put Operation)

The [`put()`](../../ContainerBuildCache/ContentAddressableCache.swift:94) method stores snapshots:

1. **Generate Cache Key**: Compute deterministic digest from operation and inputs
2. **Check Existence**: Skip if already cached
3. **Create Manifest**: Embed snapshot directly in [`CacheManifest`](../../ContainerBuildCache/ContentAddressableCache.swift:114)
4. **Store to ContentStore**: Write manifest as single artifact
5. **Update Index**: Record in cache index with metadata

```swift
// Create manifest with embedded snapshot
let manifest = createManifest(
    key: key,
    operation: operation,
    snapshot: result.snapshot,  // Direct snapshot embedding
    environmentChanges: result.environmentChanges,
    metadataChanges: result.metadataChanges
)
```

### 4. Retrieving Snapshots (Get Operation)

The [`get()`](../../ContainerBuildCache/ContentAddressableCache.swift:63) method retrieves snapshots:

1. **Generate Cache Key**: Compute same deterministic digest
2. **Check Index**: Look up entry in cache index
3. **Fetch Manifest**: Retrieve from content store using digest
4. **Extract Snapshot**: Get embedded snapshot from manifest
5. **Update Access Time**: Track LRU for eviction

```swift
private func reconstructResult(from manifest: CacheManifest) async throws -> CachedResult {
    // Snapshot is embedded directly in the manifest
    guard let snapshot = manifest.snapshot else {
        throw CacheError.storageFailed("No snapshot found in manifest")
    }
    
    return CachedResult(
        snapshot: snapshot,
        environmentChanges: manifest.environmentChanges,
        metadataChanges: manifest.metadataChanges
    )
}
```

### 5. Snapshot-Aware Eviction

The cache implements intelligent eviction that considers snapshots:

- **LRU Policy**: Least recently accessed snapshots evicted first
- **TTL Support**: Snapshots can expire based on time-to-live
- **Size Limits**: Total cache size includes manifest + snapshot metadata
- **Atomic Cleanup**: Manifest and snapshot removed together

## Cache Storage Architecture

```
┌─────────────────────────────────────────────────────┐
│                   CacheKey                           │
│  • Operation Digest                                  │
│  • Input Digests (including parent snapshots)        │
│  • Platform Information                              │
└──────────────────┬──────────────────────────────────┘
                   │ generates
                   ▼
┌─────────────────────────────────────────────────────┐
│               Cache Digest (SHA256)                  │
└──────────────────┬──────────────────────────────────┘
                   │ maps to
                   ▼
┌─────────────────────────────────────────────────────┐
│                 CacheManifest                        │
│  ┌─────────────────────────────────────────────┐    │
│  │ • Embedded Snapshot (complete state)        │    │
│  │ • Environment Changes                       │    │
│  │ • Metadata Changes                          │    │
│  │ • Annotations (timestamps, version)         │    │
│  └─────────────────────────────────────────────┘    │
└──────────────────┬──────────────────────────────────┘
                   │ stored in
                   ▼
┌─────────────────────────────────────────────────────┐
│                  ContentStore                        │
│  • Content-addressable storage                       │
│  • Deduplication by digest                          │
│  • Atomic operations                                │
└──────────────────────────────────────────────────────┘
```

## Benefits of Snapshot Integration

### 1. Performance
- **No Layer Reconstruction**: Snapshots are immediately available
- **Single Fetch**: One content store operation retrieves everything
- **Reduced I/O**: No need to materialize cached layers

### 2. Consistency
- **Atomic Storage**: Snapshot and metadata stored together
- **Version Control**: Schema versioning ensures compatibility
- **Integrity**: Content-addressable storage prevents corruption

### 3. Simplicity
- **Self-Contained**: Manifests contain complete state
- **No Dependencies**: No separate layer management required
- **Clear Lifecycle**: Snapshot lifetime tied to cache entry

## Cache Optimization Opportunities

The current implementation provides functional caching with embedded snapshots. Future optimizations could include:

1. **Snapshot Deduplication**: Share common snapshot components
2. **Incremental Snapshots**: Store only deltas for similar operations
3. **Compression**: Compress snapshot data in manifests
4. **Prefetching**: Predict and preload likely cache hits
5. **Distributed Caching**: Share snapshots across build nodes

## Summary

The ContainerBuildCache provides efficient snapshot caching through direct embedding in cache manifests. This design ensures atomic operations, simple retrieval, and consistent state management. The content-addressable nature combined with deterministic cache keys enables reliable caching across builds while maintaining snapshot integrity and lineage.