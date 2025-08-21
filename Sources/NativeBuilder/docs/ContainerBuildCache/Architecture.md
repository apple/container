# ContainerBuildCache Architecture

This document outlines the high-level architecture of ContainerBuildCache, focusing on system design, component interaction, and data flow patterns.

## Overview

The cache is designed around three key layers:

1. **BuildCache API Layer** - Public interface matching the BuildCache protocol
2. **Content-Based Cache Layer** - Manages cache entries as OCI artifacts with metadata indexing
3. **ContentStore** - Provides reliable, content-addressable storage with built-in deduplication

### Design Principles

- **Simplicity** - Clean separation of concerns with ContentStore handling storage complexity
- **Reliability** - Leverages ContentStore's atomic operations and content verification
- **Performance** - Content-addressable lookups with automatic deduplication and compression
- **Scalability** - Lightweight index with support for sharding and distributed storage
- **Maintainability** - Standard OCI artifact format with minimal custom code

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         BuildCache API                          │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐            │
│  │    get()    │   │    put()    │   │ statistics()│            │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘            │
│         │                 │                 │                   │
├─────────┴─────────────────┴─────────────────┴───────────────────┤
│                    BuildCache Implementation                    │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                 Content-Based Cache Layer               │    │
│  │  ┌───────────┐   ┌──────────────┐   ┌────────────────┐  │    │
│  │  │   Index   │   │   Manifest   │   │   Compressor   │  │    │
│  │  │  Manager  │   │   Builder    │   │    Engine      │  │    │
│  │  └─────┬─────┘   └──────┬───────┘   └────────┬───────┘  │    │
│  │        │                │                    │          │    │
│  └────────┴────────────────┴────────────────────┴──────────┘    │
│                            │                                    │
├────────────────────────────┴────────────────────────────────────┤
│                        ContentStore                             │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │   Content-Addressable Storage (CAS)                     │    │
│  │   - Deduplication                                       │    │
│  │   - Atomic Operations                                   │    │
│  │   - Content Verification                                │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

### 1. BuildCache API Layer
- **Purpose**: Provides the public interface matching the BuildCache protocol
- **Responsibilities**:
  - Input validation and sanitization
  - Error handling and user-friendly error messages
  - API versioning and backward compatibility
  - Metrics collection and logging

### 2. Content-Based Cache Layer
- **Purpose**: Manages cache entries as OCI-compliant artifacts with metadata indexing
- **Components**:
  - **Index Manager**: SQLite-based metadata storage for fast lookups
  - **Manifest Builder**: Creates OCI-compliant manifests for cache entries
  - **Compressor Engine**: Handles compression/decompression of cache data

### 3. ContentStore
- **Purpose**: Provides reliable, content-addressable storage with built-in deduplication
- **Features**:
  - Content-addressable storage (CAS) with SHA256 addressing
  - Atomic operations ensuring consistency
  - Built-in content verification and integrity checking
  - Automatic deduplication of identical content

## Data Flow Patterns

### Cache PUT Operation Flow

```
Client                BuildCache              ContentStore           Index
  │                      │                         │                   │
  ├─put(result, key)────>│                         │                   │
  │                      │                         │                   │
  │                      ├─1. Generate digest      │                   │
  │                      │    from cache key       │                   │
  │                      │                         │                   │
  │                      ├─2. Serialize components │                   │
  │                      │   - Snapshot            │                   │
  │                      │   - Environment         │                   │
  │                      │   - Metadata            │                   │
  │                      │                         │                   │
  │                      ├─3. Store blobs─────────>│                   │
  │                      │<──────blob digests──────│                   │
  │                      │                         │                   │
  │                      ├─4. Create manifest      │                   │
  │                      │                         │                   │
  │                      ├─5. Store manifest──────>│                   │
  │                      │<────manifest digest─────│                   │
  │                      │                         │                   │
  │                      ├─6. Update index────────────────────────────>│
  │                      │<───────────────────────────────success──────│
  │                      │                         │                   │
  │<────────success──────│                         │                   │
```

### Cache GET Operation Flow

```
Client                BuildCache              ContentStore           Index
  │                      │                         │                   │
  ├─get(key)────────────>│                         │                   │
  │                      │                         │                   │
  │                      ├─1. Generate digest      │                   │
  │                      │   from cache key        │                   │
  │                      │                         │                   │
  │                      ├─2. Lookup in index─────────────────────────>│
  │                      │<───────────────────────entry metadata───────│
  │                      │                         │                   │
  │                      ├─3. Fetch manifest──────>│                   │
  │                      │<────manifest data───────│                   │
  │                      │                         │                   │
  │                      ├─4. Fetch layers────────>│                   │
  │                      │<─────layer data─────────│                   │
  │                      │                         │                   │
  │                      ├─5. Reconstruct result   │                   │
  │                      │                         │                   │
  │                      ├─6. Update access time──────────────────────>│
  │                      │                         │                   │
  │<────CachedResult─────│                        │                   │
```
## Cache Key Generation

Cache keys are deterministically generated from operation characteristics:

```
CacheKey = SHA256(
    version ||
    operation_digest ||
    sorted(input_digests) ||
    normalized_platform ||
    operation_type ||
    operation_content
)
```

This ensures that identical operations with the same inputs produce the same cache key, enabling reliable cache hits across different build environments.

## Cache Entry Architecture

### OCI Artifact Structure

Each cache entry follows the OCI artifact specification:

```
Cache Entry (OCI Artifact)
├── Manifest (JSON)
│   ├── schemaVersion: 2
│   ├── mediaType: "application/vnd.container-build.cache.manifest.v2+json"
│   ├── config: CacheConfig
│   │   ├── cacheKey: SerializedCacheKey
│   │   ├── operationType: String
│   │   ├── platform: Platform
│   │   └── buildVersion: String
│   └── layers: [
│       ├── Layer 1: Snapshot Data
│       │   ├── mediaType: "application/vnd.container-build.snapshot.v1+json"
│       │   ├── digest: "sha256:..."
│       │   └── size: Int64
│       ├── Layer 2: Environment Changes (optional)
│       │   ├── mediaType: "application/vnd.container-build.environment.v1+json"
│       │   ├── digest: "sha256:..."
│       │   └── size: Int64
│       └── Layer 3: Metadata (optional)
│           ├── mediaType: "application/vnd.container-build.metadata.v1+json"
│           ├── digest: "sha256:..."
│           └── size: Int64
│       ]
└── Content Blobs
    ├── Snapshot blob (compressed)
    ├── Environment blob (if present)
    └── Metadata blob (if present)
```

### Index Architecture

The SQLite index provides fast metadata access:

```sql
-- Cache entries table
CREATE TABLE cache_entries (
    digest TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL,
    last_accessed_at INTEGER NOT NULL,
    access_count INTEGER DEFAULT 1,
    total_size INTEGER NOT NULL,
    platform_os TEXT NOT NULL,
    platform_arch TEXT NOT NULL,
    operation_type TEXT NOT NULL
);

-- Indexes for efficient queries
CREATE INDEX idx_lru ON cache_entries(last_accessed_at);
CREATE INDEX idx_age ON cache_entries(created_at);
CREATE INDEX idx_platform ON cache_entries(platform_os, platform_arch);
CREATE INDEX idx_size ON cache_entries(total_size);
```

## Eviction Architecture

### Eviction Manager

```
┌─────────────────────────────────────────┐
│          Eviction Manager               │
│                                         │
│  1. Check trigger conditions:           │
│     - Total size > maxSize              │
│     - Entry age > maxAge                │
│     - Manual trigger                    │
│                                         │
│  2. Select victims:                     │
│     - Query index by policy             │
│     - Build eviction list               │
│                                         │
│  3. Execute eviction:                   │
│     - Remove from ContentStore          │
│     - Update index                      │
│     - Log metrics                       │
└─────────────────────────────────────────┘
```

### Eviction Policies

- **LRU (Least Recently Used)**: Evicts entries with oldest access time
- **LFU (Least Frequently Used)**: Evicts entries with lowest access count
- **FIFO (First In First Out)**: Evicts entries with oldest creation time
- **TTL (Time To Live)**: Evicts entries older than specified age
- **ARC (Adaptive Replacement Cache)**: Adaptive policy balancing recency and frequency

## Concurrency Model

### Actor-Based Design

```swift
public actor ContentAddressableCache: BuildCache {
    private let contentStore: ContentStore
    private let index: CacheIndex
    private let configuration: CacheConfiguration

    // All operations are serialized through the actor
    public func get(_ key: CacheKey, for operation: ContainerBuildIR.Operation) async -> CachedResult?
    public func put(_ result: CachedResult, key: CacheKey, for operation: ContainerBuildIR.Operation) async
    public func statistics() async -> CacheStatistics
}
```

### Parallel Operations

- **Layer Storage**: Multiple layers can be stored concurrently
- **Layer Retrieval**: Parallel fetching of cache entry layers
- **Background Cleanup**: Eviction runs in background tasks
- **Index Updates**: Batched for improved performance

## Error Handling Strategy

### Graceful Degradation

1. **Index Corruption**: Rebuild from ContentStore manifests
2. **ContentStore Errors**: Fall back to cache miss behavior
3. **Partial Cache Entries**: Clean up orphaned data automatically
4. **Disk Space Issues**: Trigger aggressive eviction

### Recovery Mechanisms

- **Orphan Cleanup**: Remove index entries without corresponding ContentStore data
- **Consistency Checks**: Periodic validation of index vs ContentStore state
- **Automatic Repair**: Self-healing for common corruption scenarios

## Performance Characteristics

### Time Complexity

- **Cache Lookup**: O(1) - Direct content-addressable access
- **Cache Storage**: O(1) - Parallel layer storage
- **Eviction Query**: O(log n) - Indexed database queries
- **Index Updates**: O(1) - Single row operations

### Space Complexity

- **Deduplication**: Automatic content deduplication in ContentStore
- **Compression**: Configurable compression levels for space/CPU tradeoff
- **Index Overhead**: Minimal metadata storage in SQLite

This architecture provides a robust, scalable foundation for build caching while maintaining simplicity and leveraging proven storage technologies.

## Benefits

### Reliability
- **Atomic Operations** - ContentStore ensures crash-safe updates
- **Content Verification** - Built-in integrity checking prevents corruption
- **Deduplication** - Automatic space savings for identical content

### Performance
- **O(1) Lookups** - Content-addressable storage enables fast retrieval
- **Parallel Operations** - Concurrent layer fetching and storage
- **Compression** - Reduces I/O overhead and storage requirements

### Maintainability
- **Standard Format** - OCI artifacts are well-understood and toolable
- **Clear Data Model** - Explicit separation of concerns
- **Minimal Custom Code** - Leverages proven ContentStore implementation
