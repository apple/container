# Operations Design

Operations are the fundamental building blocks of the ContainerBuildIR. This document explains their design, implementation patterns, and the rationale behind key decisions.

## Design Overview

### Operation Protocol

```swift
public protocol Operation: Sendable {
    /// Unique type identifier
    static var operationKind: OperationKind { get }
    
    /// Instance operation kind
    var operationKind: OperationKind { get }
    
    /// Accept a visitor for traversal
    func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result
}

// Operations also conform to Codable, Hashable, and Equatable
// through protocol extensions or direct conformance
```

### Core Operation Types

1. **ExecOperation** - Command execution (RUN)
2. **FilesystemOperation** - File manipulation (COPY, ADD)
3. **ImageOperation** - Base image specification (FROM)
4. **MetadataOperation** - Container metadata (ENV, LABEL, USER)

## Design Philosophy

### 1. Protocol-Based Design

**Why**: Using protocols instead of enums provides:
- Open extensibility for custom operations
- Type safety with associated types
- Clean separation of concerns

**Tradeoff**: Requires visitor pattern for exhaustive handling, but enables third-party extensions.

### 2. Immutable Operations

**Why**: All operations are immutable value types:
- Thread-safe by default (Sendable)
- Predictable behavior
- Easy to reason about

**Tradeoff**: Modifications require creating new instances, but prevents accidental mutations.

### 3. Self-Contained Operations

**Why**: Each operation contains all information needed for execution:
- No external state dependencies
- Simplifies serialization
- Enables operation reuse

**Tradeoff**: Some data duplication possible, but ensures operation independence.

## Implementing Custom Operations

### Step 1: Define the Operation

```swift
public struct CompressOperation: Operation, Codable, Hashable {
    public let sourcePath: String
    public let algorithm: CompressionAlgorithm
    public let level: Int
    public let metadata: OperationMetadata?
    
    public static let operationKind = OperationKind(rawValue: "compress")
    public var operationKind: OperationKind { Self.operationKind }
    
    public func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
        // Custom operations use visitUnknown
        return try visitor.visitUnknown(self)
    }
}

public enum CompressionAlgorithm: String, Codable, Sendable {
    case gzip
    case bzip2
    case xz
    case zstd
}
```

### Step 2: Visitor Pattern

The OperationVisitor protocol provides methods for all built-in operations:

```swift
public protocol OperationVisitor {
    associatedtype Result
    
    func visit(_ operation: ExecOperation) throws -> Result
    func visit(_ operation: FilesystemOperation) throws -> Result
    func visit(_ operation: ImageOperation) throws -> Result
    func visit(_ operation: MetadataOperation) throws -> Result
    func visitUnknown(_ operation: Operation) throws -> Result
}
```

Custom operations are handled through `visitUnknown`, which provides a default implementation that throws an error for unrecognized operations.

### Step 3: Operation Metadata

All operations can include metadata for debugging and analysis:

```swift
public struct OperationMetadata: Codable, Hashable, Sendable {
    public let description: String?
    public let location: SourceLocation?
    public let annotations: [String: String]?
    public let cacheConfig: CacheConfig?
}

public struct SourceLocation: Codable, Hashable, Sendable {
    public let file: String?
    public let line: Int?
    public let column: Int?
}
```

### Step 4: Add Builder Support

```swift
extension StageBuilder {
    @discardableResult
    public func compress(_ path: String, algorithm: CompressionAlgorithm = .gzip, level: Int = 6) -> Self {
        let operation = CompressOperation(
            sourcePath: path,
            algorithm: algorithm,
            level: level
        )
        addNode(BuildNode(operation: operation))
        return self
    }
}
```

## Performance Considerations

### Memory Efficiency

Operations are designed to be lightweight:
- Use copy-on-write for collections
- Share common data through references
- Typical operation: 200-500 bytes

### Serialization Performance

- Codable implementation is optimized for speed
- Custom operations should implement efficient coding
- Consider using CodingKeys for stable serialization

## Best Practices

### 1. Keep Operations Focused

Each operation should do one thing well:
```swift
// Good: Single responsibility
ExecOperation(command: .shell("apt-get update"))
ExecOperation(command: .shell("apt-get install -y curl"))

// Avoid: Multiple unrelated commands
ExecOperation(command: .shell("apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*"))
```

### 2. Use Type-Safe Enums

Prefer enums over strings for operation parameters:
```swift
// Good: Type-safe
public enum PackageManager {
    case apt
    case yum
    case apk
}

// Avoid: Stringly-typed
let packageManager = "apt-get"
```

### 3. Provide Meaningful Descriptions

Implement descriptive `description` properties:
```swift
public var description: String {
    switch action {
    case .copy:
        return "Copy \(source.displayName) to \(destination)"
    case .add:
        return "Add \(source.displayName) to \(destination)"
    case .remove:
        return "Remove \(destination)"
    }
}
```

### 4. Design for Extensibility

Consider future needs when designing operations:
```swift
public struct ExecOperation: Operation {
    // Core functionality
    public let command: Command
    public let environment: Environment
    
    // Extensibility points
    public let metadata: [String: Any]?  // For future extensions
    public let extensions: OperationExtensions?  // Type-safe extensions
}
```

## Future Directions

### Potential Enhancements

1. **Operation Macros**: Higher-level operations that expand to multiple primitives
2. **Conditional Operations**: Operations that execute based on runtime conditions
3. **Parallel Operations**: Explicit parallel execution hints
4. **Operation Fragments**: Reusable operation templates

### Maintaining Backward Compatibility

- New operation types can be added without breaking existing code
- Optional properties can be added to existing operations
- The visitor pattern allows graceful handling of unknown operations