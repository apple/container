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

import ContainerizationOCI
import Foundation

/// Represents the complete build graph.
///
/// Design rationale:
/// - Immutable after construction for thread safety
/// - Supports multiple stages (multi-stage builds)
/// - Validates graph structure on creation
/// - Efficient traversal and dependency resolution
public struct BuildGraph: Sendable {
    /// All stages in the build
    public let stages: [BuildStage]

    /// Build arguments available globally
    public let buildArgs: [String: String]

    /// Target platform(s) for the build
    public let targetPlatforms: Set<Platform>

    /// Graph metadata
    public let metadata: BuildGraphMetadata

    public init(
        stages: [BuildStage],
        buildArgs: [String: String] = [:],
        targetPlatforms: Set<Platform> = [],
        metadata: BuildGraphMetadata = BuildGraphMetadata()
    ) throws {
        self.stages = stages
        self.buildArgs = buildArgs
        self.targetPlatforms = targetPlatforms.isEmpty ? [Platform.current] : targetPlatforms
        self.metadata = metadata

        // Validate graph structure
        try Self.validate(stages: stages)
    }

    /// Get stage by name
    public func stage(named name: String) -> BuildStage? {
        stages.first { $0.name == name }
    }

    /// Get stage by index
    public func stage(at index: Int) -> BuildStage? {
        guard index >= 0 && index < stages.count else { return nil }
        return stages[index]
    }

    /// Resolve a stage reference
    public func resolveStage(_ reference: StageReference) -> BuildStage? {
        switch reference {
        case .named(let name):
            return stage(named: name)
        case .index(let idx):
            return stage(at: idx)
        case .previous:
            // This needs context of current stage to resolve
            return nil
        }
    }

    /// Get the final stage (build target)
    public var targetStage: BuildStage? {
        stages.last
    }

    // MARK: - Validation

    private static func validate(stages: [BuildStage]) throws {
        // Check for duplicate stage names
        var seenNames = Set<String>()
        for stage in stages {
            if let name = stage.name {
                guard seenNames.insert(name).inserted else {
                    throw BuildGraphError.duplicateStageName(name)
                }
            }
        }

        // Collect all node IDs across all stages
        var allNodeIds = Set<UUID>()
        for stage in stages {
            for node in stage.nodes {
                allNodeIds.insert(node.id)
            }
        }

        // Validate node dependencies (can be cross-stage)
        for stage in stages {
            for node in stage.nodes {
                for dep in node.dependencies {
                    guard allNodeIds.contains(dep) else {
                        throw BuildGraphError.invalidDependency(node.id, dep)
                    }
                }
            }
        }

        // Validate DAG structure (check for cycles across entire graph)
        try validateGlobalDAG(stages: stages)
    }

    private static func validateGlobalDAG(stages: [BuildStage]) throws {
        // Build adjacency list for all nodes across all stages
        var adjacencyList: [UUID: Set<UUID>] = [:]
        var allNodes = Set<UUID>()

        for stage in stages {
            for node in stage.nodes {
                allNodes.insert(node.id)
                adjacencyList[node.id] = node.dependencies
            }
        }

        // Check for cycles using DFS
        var visited = Set<UUID>()
        var recursionStack = Set<UUID>()

        func hasCycle(from nodeId: UUID) -> Bool {
            visited.insert(nodeId)
            recursionStack.insert(nodeId)

            if let dependencies = adjacencyList[nodeId] {
                for dep in dependencies {
                    if !visited.contains(dep) {
                        if hasCycle(from: dep) {
                            return true
                        }
                    } else if recursionStack.contains(dep) {
                        return true
                    }
                }
            }

            recursionStack.remove(nodeId)
            return false
        }

        // Check each unvisited node
        for nodeId in allNodes {
            if !visited.contains(nodeId) {
                if hasCycle(from: nodeId) {
                    throw BuildGraphError.cyclicDependency
                }
            }
        }
    }
}

/// A build stage (FROM ... AS name).
///
/// Design rationale:
/// - Represents a single FROM instruction and its operations
/// - Maintains operation order for correct execution
/// - Supports both named and anonymous stages
/// - Tracks dependencies on other stages
public struct BuildStage: Sendable, Equatable {
    /// Unique identifier
    public let id: UUID

    /// Stage name (FROM ... AS name)
    public let name: String?

    /// Base image operation
    public let base: ImageOperation

    /// Nodes in this stage (topologically sorted)
    public let nodes: [BuildNode]

    /// Platform constraints for this stage
    public let platform: Platform?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        base: ImageOperation,
        nodes: [BuildNode] = [],
        platform: Platform? = nil
    ) {
        self.id = id
        self.name = name
        self.base = base
        self.nodes = nodes
        self.platform = platform
    }

    /// All operations in this stage (including base)
    public var operations: [any Operation] {
        [base] + nodes.map { $0.operation }
    }

    /// Find dependencies on other stages
    public func stageDependencies() -> Set<StageReference> {
        var deps = Set<StageReference>()

        for node in nodes {
            // Check filesystem operations for stage references
            if let fsOp = node.operation as? FilesystemOperation {
                switch fsOp.source {
                case .stage(let ref, _):
                    deps.insert(ref)
                default:
                    break
                }
            }

            // Check mount sources
            if let execOp = node.operation as? ExecOperation {
                for mount in execOp.mounts {
                    if case .stage(let ref, _) = mount.source {
                        deps.insert(ref)
                    }
                }
            }
        }

        return deps
    }

    // MARK: - Validation

    func validate() throws {
        // Stage-level validation is now done at the graph level
        // to support cross-stage dependencies
    }

}

/// A node in the build graph.
///
/// Design rationale:
/// - Represents a single operation and its dependencies
/// - Immutable for safe concurrent access
/// - Tracks both data and execution dependencies
/// - Supports caching and incremental builds
public struct BuildNode: Sendable, Equatable {
    /// Unique identifier
    public let id: UUID

    /// The operation this node performs
    public let operation: any Operation

    /// IDs of nodes this depends on
    public let dependencies: Set<UUID>

    /// Cache key for this operation
    public let cacheKey: CacheKey?

    /// Execution constraints
    public let constraints: Set<Constraint>

    public init(
        id: UUID = UUID(),
        operation: any Operation,
        dependencies: Set<UUID> = [],
        cacheKey: CacheKey? = nil,
        constraints: Set<Constraint> = []
    ) {
        self.id = id
        self.operation = operation
        self.dependencies = dependencies
        self.cacheKey = cacheKey
        self.constraints = constraints
    }

    // Custom Equatable implementation
    public static func == (lhs: BuildNode, rhs: BuildNode) -> Bool {
        // Compare by ID for node equality
        lhs.id == rhs.id
    }
}

/// Build graph metadata.
public struct BuildGraphMetadata: Sendable {
    /// Source file that generated this graph
    public let sourceFile: String?

    /// Build context path
    public let contextPath: String?

    /// Original frontend used (e.g., "dockerfile", "llb")
    public let frontend: String?

    /// Frontend version
    public let frontendVersion: String?

    /// Additional metadata
    public let attributes: [String: AttributeValue]

    public init(
        sourceFile: String? = nil,
        contextPath: String? = nil,
        frontend: String? = nil,
        frontendVersion: String? = nil,
        attributes: [String: AttributeValue] = [:]
    ) {
        self.sourceFile = sourceFile
        self.contextPath = contextPath
        self.frontend = frontend
        self.frontendVersion = frontendVersion
        self.attributes = attributes
    }
}

/// Cache key for operations.
///
/// Design rationale:
/// - Content-addressed for reliable caching
/// - Includes all inputs that affect output
/// - Platform-aware for cross-compilation
public struct CacheKey: Hashable, Sendable {
    /// Operation digest
    public let operationDigest: Digest

    /// Input digests (from dependencies)
    public let inputDigests: Set<Digest>

    /// Platform (if platform-specific)
    public let platform: Platform?

    /// Additional cache inputs
    public let additionalInputs: [String: String]

    public init(
        operationDigest: Digest,
        inputDigests: Set<Digest> = [],
        platform: Platform? = nil,
        additionalInputs: [String: String] = [:]
    ) {
        self.operationDigest = operationDigest
        self.inputDigests = inputDigests
        self.platform = platform
        self.additionalInputs = additionalInputs
    }

    /// Compute combined cache key
    public var digest: Digest {
        var data = Data()
        data.append(operationDigest.bytes)

        for input in inputDigests.sorted(by: { $0.stringValue < $1.stringValue }) {
            data.append(input.bytes)
        }

        if let platform = platform {
            data.append(contentsOf: platform.description.utf8)
        }

        for (key, value) in additionalInputs.sorted(by: { $0.key < $1.key }) {
            data.append(contentsOf: key.utf8)
            data.append(contentsOf: value.utf8)
        }

        do {
            return try Digest.compute(data)
        } catch {
            // Fallback to a deterministic digest if computation fails
            // This should never happen in practice
            return try! Digest(algorithm: .sha256, bytes: Data(count: 32))
        }
    }
}

/// Execution constraints for nodes.
public enum Constraint: Hashable, Sendable {
    /// Requires network access
    case requiresNetwork

    /// Requires privileged execution
    case requiresPrivileged

    /// Requires specific capability
    case requiresCapability(String)

    /// Must run on specific platform
    case requiresPlatform(Platform)

    /// Maximum execution time
    case timeout(TimeInterval)

    /// Maximum memory
    case memoryLimit(Int)

    /// CPU limit
    case cpuLimit(Double)
}

// MARK: - Errors

public enum BuildGraphError: LocalizedError {
    case duplicateStageName(String)
    case cyclicDependency
    case invalidDependency(UUID, UUID)
    case stageNotFound(StageReference)

    public var errorDescription: String? {
        switch self {
        case .duplicateStageName(let name):
            return "Duplicate stage name: '\(name)'"
        case .cyclicDependency:
            return "Build graph contains cyclic dependencies"
        case .invalidDependency(let node, let dep):
            return "Node \(node) has invalid dependency \(dep)"
        case .stageNotFound(let ref):
            return "Stage not found: \(ref)"
        }
    }
}

// MARK: - Codable

extension BuildGraph: Codable {}
extension BuildStage: Codable {}
extension BuildNode: Codable {
    // Custom coding to handle type-erased Operation
    enum CodingKeys: String, CodingKey {
        case id
        case operation
        case dependencies
        case cacheKey
        case constraints
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(dependencies, forKey: .dependencies)
        try container.encode(cacheKey, forKey: .cacheKey)
        try container.encode(constraints, forKey: .constraints)

        // For operation, we need type information
        // This is handled by SerializedOperation in IRCoder.swift
        // For now, skip encoding the operation directly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.dependencies = try container.decode(Set<UUID>.self, forKey: .dependencies)
        self.cacheKey = try container.decodeIfPresent(CacheKey.self, forKey: .cacheKey)
        self.constraints = try container.decode(Set<Constraint>.self, forKey: .constraints)

        // For operation, we need a placeholder
        // Real decoding is handled by SerializedNode in IRCoder.swift
        self.operation = MetadataOperation(action: .setLabel(key: "placeholder", value: "placeholder"))
    }
}
extension BuildGraphMetadata: Codable {}
extension CacheKey: Codable {}
extension Constraint: Codable {}
