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

/// Protocol for encoding/decoding operations.
///
/// Design rationale:
/// - Type-erased operations need special handling
/// - Preserve unknown operation types for forward compatibility
/// - Support multiple serialization formats
public protocol IRCoder {
    func encode(_ graph: BuildGraph) throws -> Data
    func decode(_ data: Data) throws -> BuildGraph
}

/// JSON-based IR coder.
///
/// Design rationale:
/// - Human-readable for debugging
/// - Wide tooling support
/// - Good balance of size and readability
public struct JSONIRCoder: IRCoder {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(prettyPrint: Bool = false) {
        encoder = JSONEncoder()
        decoder = JSONDecoder()

        if prettyPrint {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }

        // Configure date encoding
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func encode(_ graph: BuildGraph) throws -> Data {
        let container = try BuildGraphContainer(graph: graph)
        return try encoder.encode(container)
    }

    public func decode(_ data: Data) throws -> BuildGraph {
        let container = try decoder.decode(BuildGraphContainer.self, from: data)
        return try container.toBuildGraph()
    }
}

/// Container for serializing build graphs.
///
/// Design rationale:
/// - Wraps the graph with version information
/// - Enables format evolution
private struct BuildGraphContainer: Codable {
    let version: String
    let graph: SerializedBuildGraph

    init(graph: BuildGraph) throws {
        self.version = "1.0"
        self.graph = try SerializedBuildGraph(from: graph)
    }

    func toBuildGraph() throws -> BuildGraph {
        try graph.toBuildGraph()
    }
}

/// Serializable representation of BuildGraph.
private struct SerializedBuildGraph: Codable {
    let stages: [SerializedStage]
    let buildArgs: [String: String]
    let targetPlatforms: Set<Platform>
    let metadata: BuildGraphMetadata

    init(from graph: BuildGraph) throws {
        self.stages = try graph.stages.map { try SerializedStage(from: $0) }
        self.buildArgs = graph.buildArgs
        self.targetPlatforms = graph.targetPlatforms
        self.metadata = graph.metadata
    }

    func toBuildGraph() throws -> BuildGraph {
        let stages = try self.stages.map { try $0.toBuildStage() }
        return try BuildGraph(
            stages: stages,
            buildArgs: buildArgs,
            targetPlatforms: targetPlatforms,
            metadata: metadata
        )
    }
}

/// Serializable representation of BuildStage.
private struct SerializedStage: Codable {
    let id: UUID
    let name: String?
    let base: SerializedOperation
    let nodes: [SerializedNode]
    let platform: Platform?

    init(from stage: BuildStage) throws {
        self.id = stage.id
        self.name = stage.name
        self.base = try SerializedOperation(from: stage.base)
        self.nodes = try stage.nodes.map { try SerializedNode(from: $0) }
        self.platform = stage.platform
    }

    func toBuildStage() throws -> BuildStage {
        guard let baseOp = try base.toOperation() as? ImageOperation else {
            throw IRDecodingError.invalidOperationType(
                expected: "ImageOperation",
                actual: String(describing: type(of: base))
            )
        }

        let nodes = try self.nodes.map { try $0.toBuildNode() }

        return BuildStage(
            id: id,
            name: name,
            base: baseOp,
            nodes: nodes,
            platform: platform
        )
    }
}

/// Serializable representation of BuildNode.
private struct SerializedNode: Codable {
    let id: UUID
    let operation: SerializedOperation
    let dependencies: Set<UUID>
    let cacheKey: CacheKey?
    let constraints: Set<Constraint>

    init(from node: BuildNode) throws {
        self.id = node.id
        self.operation = try SerializedOperation(from: node.operation)
        self.dependencies = node.dependencies
        self.cacheKey = node.cacheKey
        self.constraints = node.constraints
    }

    func toBuildNode() throws -> BuildNode {
        BuildNode(
            id: id,
            operation: try operation.toOperation(),
            dependencies: dependencies,
            cacheKey: cacheKey,
            constraints: constraints
        )
    }
}

/// Serializable representation of Operation.
///
/// Design rationale:
/// - Type-erased operations need explicit type tracking
/// - Support for unknown operation types (forward compatibility)
private struct SerializedOperation: Codable {
    let kind: OperationKind
    let data: Data

    init(from operation: any Operation) throws {
        self.kind = operation.operationKind

        // Encode the specific operation type
        let encoder = JSONEncoder()
        switch operation {
        case let op as ExecOperation:
            self.data = try encoder.encode(op)
        case let op as FilesystemOperation:
            self.data = try encoder.encode(op)
        case let op as ImageOperation:
            self.data = try encoder.encode(op)
        case let op as MetadataOperation:
            self.data = try encoder.encode(op)
        default:
            // For unknown types, try generic encoding
            guard let encodable = operation as? Encodable else {
                throw IREncodingError.unsupportedOperationType(kind)
            }
            self.data = try encoder.encode(AnyEncodable(encodable))
        }
    }

    func toOperation() throws -> any Operation {
        let decoder = JSONDecoder()

        switch kind {
        case .exec:
            return try decoder.decode(ExecOperation.self, from: data)
        case .filesystem:
            return try decoder.decode(FilesystemOperation.self, from: data)
        case .image:
            return try decoder.decode(ImageOperation.self, from: data)
        case .metadata:
            return try decoder.decode(MetadataOperation.self, from: data)
        default:
            // Unknown operation type - preserve for forward compatibility
            throw IRDecodingError.unknownOperationType(kind)
        }
    }
}

/// Type-erased encodable wrapper.
private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void

    init(_ encodable: Encodable) {
        self.encode = encodable.encode
    }

    func encode(to encoder: Encoder) throws {
        try encode(encoder)
    }
}

// MARK: - Binary Coder

/// Binary IR coder for compact representation.
///
/// Design rationale:
/// - Optimized for size and speed
/// - Uses property list binary format
/// - Good for cache storage
public struct BinaryIRCoder: IRCoder {
    public init() {}

    public func encode(_ graph: BuildGraph) throws -> Data {
        // First encode to intermediate format
        let jsonCoder = JSONIRCoder()
        let jsonData = try jsonCoder.encode(graph)

        // Convert to property list
        let jsonObject = try JSONSerialization.jsonObject(with: jsonData)
        return try PropertyListSerialization.data(
            fromPropertyList: jsonObject,
            format: .binary,
            options: 0
        )
    }

    public func decode(_ data: Data) throws -> BuildGraph {
        // Decode from property list
        let plistObject = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )

        // Convert back to JSON
        let jsonData = try JSONSerialization.data(withJSONObject: plistObject)

        // Decode using JSON coder
        let jsonCoder = JSONIRCoder()
        return try jsonCoder.decode(jsonData)
    }
}

// MARK: - Errors

public enum IREncodingError: LocalizedError {
    case unsupportedOperationType(OperationKind)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperationType(let kind):
            return "Cannot encode operation type: \(kind.rawValue)"
        }
    }
}

public enum IRDecodingError: LocalizedError {
    case unknownOperationType(OperationKind)
    case invalidOperationType(expected: String, actual: String)
    case invalidFormat

    public var errorDescription: String? {
        switch self {
        case .unknownOperationType(let kind):
            return "Unknown operation type: \(kind.rawValue)"
        case .invalidOperationType(let expected, let actual):
            return "Expected \(expected) but got \(actual)"
        case .invalidFormat:
            return "Invalid IR format"
        }
    }
}

// MARK: - Convenience Extensions

extension BuildGraph {
    /// Save graph to file.
    public func save(to url: URL, using coder: IRCoder = JSONIRCoder(prettyPrint: true)) throws {
        let data = try coder.encode(self)
        try data.write(to: url)
    }

    /// Load graph from file.
    public static func load(from url: URL, using coder: IRCoder = JSONIRCoder()) throws -> BuildGraph {
        let data = try Data(contentsOf: url)
        return try coder.decode(data)
    }
}
