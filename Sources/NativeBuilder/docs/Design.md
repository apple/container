Swift Native Builder

## Introduction

Swift Native Builder is a pure-Swift container build system that replaces the current Swift+Go architecture. It leverages Containerization.framework to run each build step in isolated VMs, writing output to a content-addressable store, for faster, deterministic and reproducible builds while maintaining native performance.

### Design Principles

- **Headless**: No resident daemon. CLI spins up, orchestrates the build, and exits cleanly
- **Mac-Native**: Native integration with Containerization.framework, Swift Concurrency, Swift Data, Keychain
- **Secure by default**: Hardware-backed signing (Secure Enclave), biometric authentication, opt-in secrets via `--build-secret`
- **Fast**: Maximal parallelism with incremental caching and negligible per-step overhead
- **OCI-compliant**: Produces standard container images without external dependencies

## High-Level Architecture
```
┌─────────────────────────┐
│  builder build <path>   │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│        Parser           │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│       DAG Scheduler     │
└───────────┬─────────────┘
            │             
            │ 
            ▼                           ┌──────────────────┐
┌────────────────────────┐              │                  │
│         Executor       │◄─────────────|     Content      │
│          VM-RUN        │              |   Addressable    │
└────────────┬───────────┘              │     Store        │
             |                          │     (CAS)        │
             |                          │                  │
             │                          └────────▲─────────┘
             ▼                                   │
┌─────────────────────────┐                      │
│   Diff & Snapshotter    ├──────────────────────┘
└────────────┬────────────┘
             │
             ▼
        ┌─────────┐
        │ Signer  │
        └────┬────┘
             │
             ▼
     ┌────────────────┐
     │ OCI Image /    │
     │ ext4 block     │
     └────────────────┘
```

### Parser

The parser must be **fully Dockerfile-compliant**, supporting all current semantics. More importantly, the parser architecture must **accommodate future evolution** without breaking changes.

#### Intermediate Representation (IR)

The core of the parser is an **extensible IR** that can represent any container build operation (just like buildkit's LLB).

See [**ContainerBuildIR**](./ContainerBuildIR/) for more detailed information.

This IR is intentionally generic - it represents operations, not Dockerfile instructions. This allows:
- Any Dockerfile construct to map to these primitives
- Future instructions to reuse existing operations
- Non-Dockerfile frontends to target the same IR

#### Frontend

A **Frontend** transforms a Dockerfile into our IR:

```swift
protocol Frontend {
    associatedtype InputFormat // Dockerfile or other format
    func transform(_ input: InputFormat) throws -> BuildGraph
}

// Dockerfile frontend implementation
struct DockerfileFrontend: Frontend {
    typealias InputFormat = Dockerfile
    
    func transform(_ dockerfile: Dockerfile) throws -> BuildGraph {
        // Handles all Dockerfile semantics:
        // - Stage name resolution for COPY --from
        // - Build arg substitution
        // - Multi-stage dependency tracking
        // - Cache mount specifications
    }
}
```

This separation enables:
- Multiple frontend languages (Dockerfile, Buildkit LLB, future formats)
- Frontend-specific optimizations without affecting the build engine
- Easier testing of language semantics vs execution semantics

#### Build Graph

The parser's only job is to produce a valid AST. All semantic understanding (stage references, variable substitution, etc.) happens in the construction of the Build Graph.

The Build Graph is a directed acyclic graph (DAG) of operations, where each node represents an operation and each edge represents a dependency between operations. This clean separation ensures we can evolve the language without touching the core build engine.


See [**ContainerBuildIR**](./ContainerBuildIR/) for more detailed information.

### Scheduler

The Scheduler orchestrates the execution of the build graph once it's fully constructed by the parser. It analyzes the dependency graph to maximize parallelism, executing all nodes whose input artifacts are available while respecting the topological ordering of dependencies.

#### Core Components

A complete build operation requires three components (Scheduler, Executor, Cache) working in concert.

#### Execution Flow

1. **Initialization**: Scheduler receives the complete BuildGraph from the parser
2. **Dependency Analysis**: Identifies nodes with no dependencies (typically base image pulls)
3. **Parallel Execution**: Launches concurrent tasks for all executable nodes
4. **Artifact Storage**: Each completed node's output is immediately written to the CAS
5. **Progress Tracking**: As nodes complete, their artifacts unlock dependent nodes
6. **Completion**: Returns when all nodes have executed successfully

#### Cache Integration

The scheduler treats the CAS as the source of truth for artifacts.

This architecture enables:
- Maximum parallelism within dependency constraints
- Cache-aware execution to skip redundant work
- Clean separation between scheduling logic and execution mechanics
- Support for speculative execution

### Executor Registry

The Executor Registry maintains a collection of executors, each advertising specific capabilities. For any given operation and its constraints, the registry selects the first matching executor.

#### Built-in Executors

| Executor | Operations | Description |
|----------|------------|-------------|
| `VMExecutor` | `RUN`, `SHELL` | Spins up LinuxKit VM, mounts parent layer via virtio-fs |
| `NativeExecutor` | `COPY`, `ADD` | Direct filesystem operations with copy-on-write |
| `CacheExecutor` | `--mount=type=cache` | Manages persistent cache directories |
| `MetadataExecutor` | `ENV`, `LABEL`, `ARG` | Updates image config without execution |

The registry uses first-match selection, allowing specialized executors (WASM, GPU) to take precedence over general-purpose ones.

### Differ & Snapshotter

The Differ and Snapshotter work together to capture filesystem changes after each build step, converting them into portable OCI layers.

#### Differ

The Differ computes the delta between filesystem states before and after an operation:

#### Snapshotter

The Snapshotter manages filesystem snapshots and converts layers to OCI format:

#### Layer Format

Each layer follows the OCI Image Layer Specification:

```
layer.tar.gz
├── bin/
│   └── myapp          # Added file
├── etc/
│   └── config.json    # Modified file
├── .wh.oldfile        # Deletion marker
└── .wh..wh..opq       # Opaque directory marker
```

This architecture enables:
- Efficient storage through deduplication
- Fast layer generation using native filesystem features
- Full OCI compatibility for cross-platform deployment
- Minimal overhead for unchanged files


### Content-Addressable Store (CAS)

The CAS serves as the central artifact repository, storing all build outputs indexed by content hash. Its design mirrors containerd's content store for compatibility.

#### Storage Layout

```
content/
├── sha256/
│   ├── 44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a
│   ├── 6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b
│   └── ...
└── metadata/
    └── ...
```

#### Pluggable Backends

The protocol enables multiple storage implementations:
- `LocalCache`: Filesystem-based storage with atomic writes
- `S3Cache`: Remote storage for distributed builds
- `HybridCache`: Tiered storage with local fast path

### Security 

Swift Native Builder leverages macOS security features to protect secrets and ensure image integrity.

#### Secret Management

Build secrets are stored in the system Keychain with hardware-backed encryption. Secrets are injected at build time without persisting in layers.

```bash
# Use in build without exposing in image
builder build --build-secret=id=github-token,target=/run/secrets/token .
```

#### Image Signing

Every built image is cryptographically signed using the Secure Enclave:

#### Trust Verification

Images are verified before execution.

This architecture provides:
- Zero-trust secret management with biometric protection
- Hardware-backed image signatures
- Transparent verification without runtime overhead
- Compatibility with existing OCI signature specifications

### Future Work

* SBOM and provenance generation
* Support for additional image formats (e.g. OCI, Docker, etc.)
