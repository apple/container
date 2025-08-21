# ContainerBuildExecutor Cache and Snapshot Integration

## Overview

The ContainerBuildExecutor orchestrates the interaction between the cache system and snapshotter to enable efficient build execution. It checks for cached operations, loads cached snapshots when available, and stores new results for future reuse.

## Cache Integration Flow

### 1. Cache Key Computation

The [`computeCacheKey()`](../../ContainerBuildExecutor/Scheduler.swift:824) method generates deterministic cache keys:

```swift
private func computeCacheKey(
    node: BuildNode,
    context: ExecutionContext
) throws -> CacheKey {
    var inputDigests: [Digest] = []
    
    // Add parent snapshot digest
    if let parentSnapshot = context.headSnapshot {
        inputDigests.append(parentSnapshot.digest)
    }
    
    // Add dependency snapshots
    for depId in node.dependencies {
        if let depSnapshot = context.snapshot(for: depId) {
            inputDigests.append(depSnapshot.digest)
        }
    }
    
    // Compute operation digest
    let operationDigest = try node.operation.contentDigest()
    
    return CacheKey(
        operationDigest: operationDigest,
        inputDigests: inputDigests,
        platform: context.platform
    )
}
```

Key components:
- **Operation Digest**: Deterministic hash of the operation itself
- **Input Digests**: Parent and dependency snapshot digests
- **Platform**: Ensures platform-specific builds are cached separately

### 2. Cache Lookup Before Execution

The [`executeNode()`](../../ContainerBuildExecutor/Scheduler.swift:666) method checks cache before executing:

```swift
// Compute cache key for this operation
let cacheKey = try computeCacheKey(node: node, context: context)

// Check cache for existing result
if let cached = await cache.get(cacheKey, for: node.operation) {
    await executionState.incrementCacheHits()
    
    // Load the cached snapshot directly
    context.setSnapshot(cached.snapshot, for: node.id)
    
    // Apply cached environment changes
    context.applyEnvironmentChanges(cached.environmentChanges)
    
    // Apply cached metadata changes
    context.applyMetadataChanges(cached.metadataChanges)
    
    return  // Skip execution, use cached result
}
```

This process:
1. **Generates Cache Key**: Based on operation and current state
2. **Queries Cache**: Async lookup in content-addressable cache
3. **Loads Snapshot**: Sets cached snapshot in execution context
4. **Applies Changes**: Restores environment and metadata
5. **Skips Execution**: Avoids redundant work

### 3. Snapshot Loading from Cache

When a cache hit occurs, the cached snapshot is loaded:

```swift
// From cached result
context.setSnapshot(cached.snapshot, for: node.id)
```

The [`setSnapshot()`](../../ContainerBuildExecutor/ExecutionContext.swift:164) method:
- Stores the snapshot for the node ID
- Updates the head snapshot pointer
- Makes it available for dependent operations

The cached snapshot contains:
- **Digest**: Content hash of the filesystem state
- **Size**: Total size of the snapshot
- **Parent**: Reference to parent snapshot (if any)
- **State**: Committed state with layer information
- **DiffKey**: For efficient layer reuse

### 4. Executing Non-Cached Operations

When no cache hit occurs, the operation executes normally:

```swift
// Execute through dispatcher
let result = try await dispatcher.dispatch(node.operation, context: context)

// The result includes a new snapshot
context.setSnapshot(result.snapshot, for: node.id)

// Store in cache for future use
let cachedResult = CachedResult(
    snapshot: result.snapshot,
    environmentChanges: result.environmentChanges,
    metadataChanges: result.metadataChanges
)
await cache.put(cachedResult, key: cacheKey, for: node.operation)
```

### 5. Snapshot State During Execution

The execution flow with snapshots:

```
Cache Hit Path:
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Compute Key │────▶│ Cache.get() │────▶│Load Snapshot│
└─────────────┘     └─────────────┘     └─────────────┘
                           │                     │
                      (found)                    ▼
                           │              ┌─────────────┐
                           └─────────────▶│Use Cached   │
                                          │   Result    │
                                          └─────────────┘

Cache Miss Path:
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Compute Key │────▶│ Cache.get() │────▶│   Execute   │
└─────────────┘     └─────────────┘     │  Operation  │
                           │             └─────────────┘
                      (not found)               │
                           │                     ▼
                           │             ┌─────────────┐
                           └────────────▶│  Prepare    │
                                         │  Snapshot   │
                                         └─────────────┘
                                                │
                                                ▼
                                         ┌─────────────┐
                                         │   Commit    │
                                         │  Snapshot   │
                                         └─────────────┘
                                                │
                                                ▼
                                         ┌─────────────┐
                                         │ Cache.put() │
                                         └─────────────┘
```

## Execution Context Integration

The [`ExecutionContext`](../../ContainerBuildExecutor/ExecutionContext.swift:28) manages the snapshot lifecycle during execution:

### Cache Hit Scenario

When loading from cache:
1. **No Prepare**: Cached snapshot is already committed
2. **Direct Assignment**: Snapshot set in context immediately
3. **No Cleanup**: No active snapshots to clean up
4. **Immediate Availability**: Snapshot ready for dependent operations

### Cache Miss Scenario

When executing operations:
1. **Prepare Snapshot**: [`prepareSnapshot()`](../../ContainerBuildExecutor/ExecutionContext.swift:203) creates working directory
2. **Execute Operation**: Operation modifies prepared snapshot
3. **Commit Snapshot**: [`commitSnapshot()`](../../ContainerBuildExecutor/ExecutionContext.swift:252) finalizes changes
4. **Store in Cache**: Committed snapshot saved for reuse

## Benefits of Cache Integration

### 1. Performance Optimization

- **Skip Expensive Operations**: Avoid re-executing costly operations
- **Reuse Snapshots**: No need to recreate filesystem states
- **Parallel Cache Checks**: Multiple operations can check cache concurrently
- **Fast Lookups**: Content-addressable storage enables O(1) lookups

### 2. Consistency Guarantees

- **Deterministic Keys**: Same inputs always produce same cache key
- **Snapshot Integrity**: Cached snapshots maintain complete state
- **Atomic Operations**: Cache operations are atomic and consistent
- **Lineage Preservation**: Parent relationships maintained in cache

### 3. Resource Efficiency

- **Reduced I/O**: Avoid filesystem operations for cached results
- **Memory Efficiency**: Snapshots shared across operations
- **Network Savings**: Cached results avoid remote operations
- **Storage Deduplication**: Content-addressable storage prevents duplicates

## Cache Statistics and Monitoring

The executor tracks cache performance:

```swift
// From ExecutionState
await executionState.incrementCacheHits()
await executionState.incrementCacheMisses()

// Cache statistics
let stats = await cache.statistics()
// - Entry count
// - Total size
// - Hit rate
// - Eviction metrics
```

## Advanced Cache Strategies

### 1. Stage-Level Caching

The executor caches at multiple levels:
- **Operation Level**: Individual operations cached
- **Stage Level**: Complete stage results cached
- **Build Level**: Final artifacts cached

### 2. Parallel Execution with Cache

```swift
// Execute stages in parallel, checking cache for each
try await withThrowingTaskGroup(of: (UUID, String?, Snapshot).self) { group in
    for stage in stagesToRun {
        group.addTask {
            // Each task checks cache independently
            let context = ExecutionContext(...)
            
            // Check stage-level cache
            if let cached = await checkStageCache(stage) {
                return (stage.id, stage.name, cached)
            }
            
            // Execute if not cached
            let snapshot = try await self.executeStage(stage, context: context)
            return (stage.id, stage.name, snapshot)
        }
    }
}
```

### 3. Cache Warming

Future optimizations could include:
- **Predictive Caching**: Pre-compute likely operations
- **Distributed Cache**: Share cache across build nodes
- **Cache Prefetching**: Load related cache entries in advance

## Integration Points

### 1. Scheduler → Cache
- Computes cache keys
- Queries cache before execution
- Stores results after execution

### 2. Cache → Snapshotter
- Returns committed snapshots
- Preserves snapshot state and metadata
- Maintains snapshot lineage

### 3. ExecutionContext → Snapshotter
- Manages snapshot lifecycle
- Ensures proper prepare/commit flow
- Handles cleanup on failure

### 4. Dispatcher → Executors
- Passes snapshots to operation executors
- Receives new snapshots from executors
- Maintains snapshot chain

## Example: Complete Cache Flow

```swift
// 1. Scheduler computes cache key
let cacheKey = try computeCacheKey(node: node, context: context)

// 2. Check cache
if let cached = await cache.get(cacheKey, for: node.operation) {
    // 3a. Cache hit: Use cached snapshot
    context.setSnapshot(cached.snapshot, for: node.id)
    context.applyEnvironmentChanges(cached.environmentChanges)
    return
}

// 3b. Cache miss: Execute operation
let (output, finalSnapshot) = try await context.withSnapshot { snapshot in
    // 4. Operation executes with prepared snapshot
    try await executeCommand(operation, in: snapshot, context: context)
}

// 5. Store result in cache
let cachedResult = CachedResult(
    snapshot: finalSnapshot,
    environmentChanges: result.environmentChanges,
    metadataChanges: result.metadataChanges
)
await cache.put(cachedResult, key: cacheKey, for: node.operation)

// 6. Snapshot available for dependent operations
context.setSnapshot(finalSnapshot, for: node.id)
```

## Summary

The ContainerBuildExecutor seamlessly integrates caching with snapshot management to provide efficient build execution. By checking cache before operations, loading cached snapshots directly, and storing results for future use, the system minimizes redundant work while maintaining consistency and correctness. The integration ensures that cached operations produce identical results to fresh execution, with significant performance benefits.