# Swift Native Builder Documentation

Welcome to the Swift Native Builder documentation. These docs contain detailed information about the project's architecture and design decisions.

## Documentation Structure

### Core Documentation

- [**Design.md**](./Design.md) - Complete architectural design and implementation details
  - High-level architecture overview
  - Component descriptions (Parser, Scheduler, Executor, CAS)
  - Security model and extensibility

### Component Documentation

- [**ContainerBuildIR**](./ContainerBuildIR/) - Intermediate Representation documentation
  - Core types and operations
  - Build graph structure
  - Validation and analysis tools

- [**ContainerBuildExecutor**](./ContainerBuildExecutor/) - Execution layer documentation
  - Executor architecture and patterns

- [**ContainerBuildCache**](./ContainerBuildCache/) - Caching layer documentation
  - ContentStore-based cache architecture
  - OCI-compliant cache entry format
  - Eviction policies and index management

## Quick Links

- [Project README](../README.md) - Getting started and overview
- [Examples](../Sources/ContainerBuildDemo/) - Sample code and usage patterns

## Contributing

When adding new documentation:
1. Place architectural documents in this docs folder
2. Component-specific documentation goes under `docs/<component-name>/`
3. Update this README with links to new documents