# ContainerBuildSnapshotter Architecture

## Overview

The ContainerBuildSnapshotter is a core subsystem in NativeBuilder that provides efficient filesystem snapshotting and diffing capabilities. It enables incremental builds, caching, and state management by tracking changes between filesystem states.

## Core Components

### 1. DiffKey - The Heart of the Differ System

[`DiffKey`](../../ContainerBuildSnapshotter/DiffKey.swift:29) is the cornerstone of the entire diffing system. It provides a canonical, Merkle-based diff key for filesystem layer reuse that enables quick and unique identification of previously computed diffs.

#### Key Characteristics

- **Deterministic Computation**: The key is computed deterministically from the ordered set of filesystem changes between (base, target) snapshots
- **Merkle Tree Structure**: Uses a Merkle tree approach to compute a root hash from all changes
- **Content-Aware**: Incorporates normalized metadata and per-entry content digests where applicable
- **Namespaced and Versioned**: The final key is namespaced ("diffkey:v1") and versioned for forward compatibility
- **String Encoding**: Encoded as "sha256:<hex>" for easy persistence and interchange

#### How DiffKey Works

1. **Change Canonicalization**: Each filesystem change (added, modified, deleted) is converted into a stable string representation:
   - Added files: `"A|<path>|<node>|<perms>|<uid>|<gid>|<link>|xh:<xattr-hash>|ch:<content-hash>"`
   - Modified files: `"M|<path>|<kind>|<node>|<perms>|<uid>|<gid>|<link>|xh:<xattr-hash>|ch:<content-hash>"`
   - Deleted files: `"D|<path>"`

2. **Sorting**: Changes are sorted canonically by path-first ordering to remove traversal nondeterminism

3. **Merkle Root Computation**: 
   - Each canonicalized change becomes a leaf in the Merkle tree
   - SHA256 hashes are computed for each leaf
   - The tree is built bottom-up, pairing adjacent nodes until a single root remains

4. **Domain Separation**: The final key incorporates:
   - A versioned prefix: "diffkey:v1"
   - The base snapshot digest (or "scratch" for initial layers)
   - This coupling ensures that diffs are tied to their lineage

#### Why DiffKey is Critical

The [`DiffKey.compute()`](../../ContainerBuildSnapshotter/DiffKey.swift:86) method enables:

- **Fast Cache Lookups**: Previously computed diffs can be quickly identified without re-computing the actual diff
- **Deduplication**: Identical filesystem changes produce identical keys, preventing redundant storage
- **Verification**: The deterministic nature allows verification that a cached diff matches expected changes
- **Layer Reuse**: In distributed builds, layers with the same DiffKey can be shared across nodes

### 2. Differ - Computing and Applying Differences

The [`Differ`](../../ContainerBuildSnapshotter/Differ.swift:28) protocol defines the contract for computing and storing filesystem diffs. The concrete implementation [`TarArchiveDiffer`](../../ContainerBuildSnapshotter/TarArchiveDiffer.swift:32) provides full OCI-compliant layer generation.

#### Diff Operation

The [`diff()`](../../ContainerBuildSnapshotter/Differ.swift:48) method performs the complete diff workflow:

1. **Validate Snapshots**: Ensures both base and target snapshots are in the "prepared" state with accessible mountpoints
2. **Compute Changes**: Uses [`DirectoryDiffer`](../../ContainerBuildSnapshotter/DirectoryDiffer.swift) to walk both filesystem trees and identify:
   - Added files and directories
   - Modified files (content, metadata, or type changes)
   - Deleted entries
3. **Stage Tar Inputs**: Prepares files for archiving:
   - Added/modified files are referenced from the target mountpoint
   - Deleted files are represented as OCI whiteout markers (`.wh.<filename>`)
   - Extended attributes are stored in sidecar files (`.container/xattrs/<path>.bin`)
4. **Stream to Content Store**: Creates a tar archive with optional compression (gzip, zstd, estargz)
5. **Generate Descriptor**: Returns an OCI descriptor with:
   - Media type indicating the compression format
   - Digest (SHA256 of the compressed layer)
   - Size in bytes
   - Annotations for metadata

#### Apply Operation

The [`apply()`](../../ContainerBuildSnapshotter/Differ.swift:65) method reverses the diff process:

1. **Fetch Diff**: Retrieves the diff from the content store using the descriptor's digest
2. **Decompress**: Based on the media type, applies appropriate decompression
3. **Extract Archive**: Processes the tar archive entry by entry:
   - Regular files are written to disk
   - Directories are created with proper permissions
   - Symbolic links are recreated
   - OCI whiteouts trigger deletions
   - Extended attributes are restored from sidecars
4. **Return Snapshot**: Creates a new snapshot representing the applied state

### 3. Snapshotter - Managing Filesystem State

The [`Snapshotter`](../../ContainerBuildSnapshotter/Snapshotter.swift:24) protocol defines the lifecycle management for filesystem snapshots. The [`TarArchiveSnapshotter`](../../ContainerBuildSnapshotter/TarArchiveSnapshotter.swift:61) provides the concrete implementation.

#### How Snapshotter Uses Differ

The Snapshotter orchestrates the Differ to manage snapshot transitions:

1. **During Prepare**: 
   - Ensures mountpoints exist for working with filesystem state
   - Materializes parent snapshots if needed (extracts committed layers to filesystem)
   - Caches materialized bases for efficient diffing

2. **During Commit**:
   - Resolves the base snapshot (parent) for diffing
   - Calls [`differ.diff()`](../../ContainerBuildSnapshotter/TarArchiveDiffer.swift:119) to compute and store the layer
   - Computes the [`DiffKey`](../../ContainerBuildSnapshotter/TarArchiveSnapshotter.swift:156) for the changes
   - Returns a committed snapshot with layer metadata

3. **For Materialization**:
   - Uses [`differ.applyChain()`](../../ContainerBuildSnapshotter/TarArchiveDiffer.swift:444) to reconstruct filesystem state
   - Applies parent layers first, then the current layer
   - Handles OCI layer semantics (whiteouts, opaque directories)

### 4. Snapshotter Lifecycle

The snapshot lifecycle follows a clear state machine:

```
┌─────────┐  prepare()  ┌──────────┐  commit()  ┌───────────┐
│  Base   │────────────▶│ Prepared │───────────▶│ Committed │
└─────────┘             └──────────┘            └───────────┘
                              │                        │
                              │ remove()               │ remove()
                              ▼                        ▼
                         ┌──────────┐            ┌──────────┐
                         │ Cleaned  │            │ Cleaned  │
                         └──────────┘            └──────────┘
```

#### States

1. **Base/Initial**: A snapshot is created with a digest and optional parent reference
2. **Prepared** ([`prepare()`](../../ContainerBuildSnapshotter/Snapshotter.swift:28)):
   - Mountpoint directory is created or verified
   - Parent snapshot is materialized if needed
   - Snapshot is ready for filesystem operations
3. **Committed** ([`commit()`](../../ContainerBuildSnapshotter/Snapshotter.swift:35)):
   - Changes are computed via Differ
   - Layer is stored to content store
   - DiffKey is calculated for caching
   - Snapshot transitions to immutable committed state
4. **Removed** ([`remove()`](../../ContainerBuildSnapshotter/Snapshotter.swift:41)):
   - Working directories are cleaned up
   - Only affects prepared snapshots (committed ones persist in content store)

### 5. Executor Integration

The [`ExecutionContext`](../../ContainerBuildExecutor/ExecutionContext.swift:28) manages snapshotter integration for the build executor:

#### Snapshot Management

1. **Prepare Phase** ([`prepareSnapshot()`](../../ContainerBuildExecutor/ExecutionContext.swift:203)):
   - Creates child snapshots linked to parent
   - Ensures one operation at a time modifies filesystem (via semaphore)
   - Tracks active snapshots for cleanup

2. **Commit Phase** ([`commitSnapshot()`](../../ContainerBuildExecutor/ExecutionContext.swift:252)):
   - Finalizes the snapshot after successful operation
   - Updates the head pointer to the latest commit
   - Removes from active tracking

3. **Cleanup** ([`cleanupSnapshot()`](../../ContainerBuildExecutor/ExecutionContext.swift:274)):
   - Removes prepared snapshots on operation failure
   - Ensures no resource leaks

#### Operation Execution Pattern

The [`withSnapshot()`](../../ContainerBuildExecutor/ExecutionContext.swift:327) helper provides a clean pattern:

```swift
let (result, finalSnapshot) = try await context.withSnapshot { snapshot in
    // Perform filesystem operations in the prepared snapshot
    try await performWork(in: snapshot)
}
```

This ensures:
- Serial execution of filesystem operations (prevents divergent branches)
- Automatic cleanup on failure
- Proper state transitions

#### Executor Usage

Different operation executors use snapshots differently:

1. **[`ImageOperationExecutor`](../../ContainerBuildExecutor/Executors/ImageOperationExecutor.swift:85)**: Creates base snapshots from pulled images
2. **[`FilesystemOperationExecutor`](../../ContainerBuildExecutor/Executors/FilesystemOperationExecutor.swift:44)**: Modifies filesystem via COPY/ADD operations
3. **[`ExecOperationExecutor`](../../ContainerBuildExecutor/Executors/ExecOperationExecutor.swift:44)**: Executes commands in prepared snapshots
4. **[`MetadataOperationExecutor`](../../ContainerBuildExecutor/Executors/MetadataOperationExecutor.swift:188)**: Reuses parent snapshots (no filesystem changes)

### 6. Additional Concepts

#### Layer Caching

The system supports multiple levels of caching:

1. **DiffKey-based Cache**: Quick lookup of previously computed diffs
2. **Content Store**: Deduplicates identical layer content by digest
3. **Materialized Base Cache**: Keeps extracted parent filesystems for faster diffing

#### OCI Compliance

The implementation follows OCI layer specifications:

- **Whiteout Files**: `.wh.<filename>` markers indicate deletions
- **Opaque Directories**: `.wh..wh..opq` clears directory contents
- **Media Types**: Proper content type headers for different compression formats
- **Layer Ordering**: Changes are applied in order (base to derived)

#### Optimization Strategies

1. **Streaming Architecture**: Diffs are streamed directly to content store without intermediate files
2. **Parallel Base Materialization**: Parent snapshots can be materialized concurrently
3. **Lazy Materialization**: Parent layers are only extracted when needed for diffing
4. **Metadata Normalization**: Timestamps and attributes are normalized for reproducibility

#### Error Handling

The system includes comprehensive error handling:

- **State Validation**: Operations verify snapshots are in expected states
- **Cleanup Guarantees**: Active snapshots are cleaned up even on failure
- **Resource Limits**: Configurable limits prevent resource exhaustion
- **Atomic Operations**: Snapshot transitions are atomic to prevent corruption

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                         Executor                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              ExecutionContext                       │    │
│  │  • Manages snapshot lifecycle                       │    │
│  │  • Ensures serial FS operations                     │    │
│  │  • Tracks active/committed snapshots                │    │
│  └──────────────────────┬──────────────────────────────┘    │
└─────────────────────────┼────────────────────────────────┘
                          │ uses
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    Snapshotter                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │           TarArchiveSnapshotter                     │    │
│  │  • prepare(): Set up working directory              │    │
│  │  • commit(): Compute diff and store layer           │    │
│  │  • remove(): Clean up working directories           │    │
│  └──────────────────────┬──────────────────────────────┘    │
└─────────────────────────┼────────────────────────────────┘
                          │ uses
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                        Differ                                │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              TarArchiveDiffer                       │    │
│  │  • diff(): Compute changes and create tar layer     │    │
│  │  • apply(): Extract and apply tar layer             │    │
│  │  • Uses DirectoryDiffer for change detection        │    │
│  └──────────────────────┬──────────────────────────────┘    │
└─────────────────────────┼────────────────────────────────┘
                          │ computes
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                       DiffKey                                │
│  • Merkle-based canonical diff identifier                    │
│  • Enables fast cache lookups                                │
│  • Ensures reproducible builds                               │
│  • Format: "sha256:<hex>"                                    │
└───────────────────────────────────────────────────────────┘
```

## Summary

The ContainerBuildSnapshotter provides a robust, efficient, and OCI-compliant system for managing filesystem snapshots during container builds. The DiffKey enables fast caching and deduplication, while the layered architecture separates concerns between snapshot lifecycle (Snapshotter), diff computation (Differ), and build orchestration (Executor). This design enables incremental builds, efficient caching, and reliable state management throughout the build process.