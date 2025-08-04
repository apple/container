# Build Graph Architecture

The ContainerBuildIR build graph is a directed acyclic graph (DAG) that represents the sequence of operations needed to build a container image. This document explains the design decisions, tradeoffs, and implementation details.

## Design Overview

### Core Structure

```swift
BuildGraph
├── stages: [BuildStage]
├── targetStage: BuildStage?
├── buildArgs: [String: BuildArg]
└── targetPlatforms: [Platform]

BuildStage
├── name: String?
├── base: ImageOperation
├── nodes: [BuildNode]
└── platform: Platform?

BuildNode
├── id: UUID
├── operation: Operation
└── dependencies: Set<UUID>
```

### Design Rationale

#### 1. Stage-Based Organization

**Why**: Container builds naturally organize into stages (multi-stage builds), where each stage can:
- Start from a different base image
- Be referenced by other stages
- Produce intermediate artifacts

**Tradeoff**: Adds complexity compared to a flat operation list, but enables:
- Clear separation of build phases
- Efficient layer caching strategies
- Support for `COPY --from` patterns

#### 2. UUID-Based Node Identity

**Why**: Using UUIDs for node identification provides:
- Guaranteed uniqueness without coordination
- Stable references across graph transformations
- No naming conflicts

**Tradeoff**: Less human-readable than string names, but ensures correctness in complex graphs.

#### 3. Explicit Dependencies

**Why**: Each node explicitly declares its dependencies rather than relying on insertion order:
- Enables parallel execution of independent operations
- Makes the graph self-documenting
- Simplifies graph analysis and optimization

**Tradeoff**: Requires explicit dependency management, but prevents implicit ordering bugs.

## Graph Construction

### Using GraphBuilder

The `GraphBuilder` provides a fluent API for constructing graphs:

```swift
// Single-stage build
let graph = try GraphBuilder.singleStage(
    from: ImageReference(parsing: "ubuntu:22.04")!,
    platform: .linuxAMD64
) { builder in
    builder
        .run("apt-get update")
        .run("apt-get install -y python3")
        .workdir("/app")
        .copyFromContext(["*.py"], to: "/app/")
        .cmd(Command.exec(["python3", "app.py"]))
}
```

## Dependency Management

### Automatic Dependencies

The GraphBuilder automatically manages dependencies based on operation order:

```swift
builder
    .run("command1")  // No dependencies
    .run("command2")  // Depends on command1
    .run("command3")  // Depends on command2
```

### Cross-Stage Dependencies

Dependencies between stages are tracked through stage references:

```swift
// This creates an implicit dependency on the "builder" stage
.copyFromStage(.named("builder"), paths: ["/app"], to: "/")
```

### Parallel Operations

Operations without dependencies can execute in parallel:

```swift
// These operations have no interdependencies
let node1 = BuildNode(operation: op1, dependencies: [])
let node2 = BuildNode(operation: op2, dependencies: [])
let node3 = BuildNode(operation: op3, dependencies: [node1.id, node2.id])
// node1 and node2 can run in parallel, node3 waits for both
```

## Graph Analysis

### Traversal Utilities

The framework provides utilities for graph analysis:

```swift
// Topological sort for execution order
let executionOrder = try GraphTraversal.topologicalSort(stage)

// Find entry points (nodes with no dependencies)
let roots = GraphTraversal.findRoots(in: stage)

// Find terminal nodes
let leaves = GraphTraversal.findLeaves(in: stage)

// Check for cycles
GraphTraversal.detectCycles(in: stage) // Throws if cycles exist
```

### Visitor Pattern

Use the visitor pattern to analyze or transform the graph:

```swift
class DependencyAnalyzer: OperationVisitor {
    private var packageCommands: [String] = []
    
    func visit(_ operation: ExecOperation) {
        if case .shell(let cmd) = operation.command,
           cmd.contains("apt-get install") || cmd.contains("pip install") {
            packageCommands.append(cmd)
        }
    }
}

// Apply visitor to all operations
let analyzer = DependencyAnalyzer()
for stage in graph.stages {
    for node in stage.nodes {
        node.operation.accept(analyzer)
    }
}
```

## Best Practices

### 1. Keep Stages Focused

Each stage should have a single responsibility:
- Dependencies stage
- Build stage
- Runtime stage

### 2. Minimize Inter-Stage Dependencies

Reduce coupling between stages by only copying necessary artifacts:

```swift
// Good: Copy only the binary
.copyFromStage(.named("builder"), paths: ["/app/binary"], to: "/usr/local/bin/")

// Avoid: Copying entire directories unnecessarily
.copyFromStage(.named("builder"), paths: ["/"], to: "/")
```

### 3. Use Platform-Specific Stages

When building for multiple platforms:

```swift
let graph = BuildGraph(
    stages: stages,
    targetPlatforms: [.linuxAMD64, .linuxARM64]
)
```

### 4. Leverage Validation

Always validate graphs before execution:

```swift
let validator = StandardValidator()
let result = validator.validate(graph)
if !result.isValid {
    // Handle validation errors
}
```

## Performance Considerations

### Memory Usage

- Graphs are immutable after construction
- Node operations are copy-on-write
- Large graphs (1000+ nodes) use ~100KB of memory

### Construction Performance

- GraphBuilder uses efficient array building
- O(1) node insertion
- O(n) validation where n is node count

### Traversal Performance

- Topological sort: O(V + E) where V is vertices, E is edges
- Cycle detection: O(V + E)
- Visitor traversal: O(V)

## Future Considerations

### Potential Enhancements

1. **Subgraph Extraction**: Extract portions of the graph for partial builds
2. **Graph Merging**: Combine multiple graphs for complex workflows
3. **Lazy Evaluation**: Defer operation construction until needed
4. **Graph Caching**: Serialize graphs for faster subsequent loads

### Maintaining Compatibility

The graph structure is designed for extensibility:
- New operation types can be added without breaking existing graphs
- Additional metadata can be attached to nodes
- Stage properties can be extended