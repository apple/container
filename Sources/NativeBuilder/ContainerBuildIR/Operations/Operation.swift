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
import Crypto
import Foundation

/// Errors that can occur during operation processing.
public enum OperationError: LocalizedError {
    case encodingFailed(String)
    case digestComputationFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let details):
            return "Failed to encode operation data: \(details)"
        case .digestComputationFailed(let error):
            return "Failed to compute operation digest: \(error.localizedDescription)"
        }
    }
}

/// Core operation protocol that all build operations must conform to.
///
/// Design rationale:
/// - Protocol-based design allows extending with new operations without modifying existing code
/// - Each operation is self-contained with all necessary data
/// - Operations are immutable for thread safety and predictable behavior
/// - Visitor pattern support for traversal and transformation
public protocol Operation: Sendable {
    /// Common metadata associated with this operation.
    var metadata: OperationMetadata { get }

    /// Unique identifier for this operation type
    static var operationKind: OperationKind { get }

    /// Instance identifier
    var operationKind: OperationKind { get }

    /// Accept a visitor for traversal/transformation
    func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result
}

/// Identifies the type of operation.
///
/// Design rationale:
/// - String-based for extensibility (third-party operations)
/// - Comparable for consistent ordering
/// - Provides namespace for operation types
public struct OperationKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Core operation kinds
    public static let exec = OperationKind(rawValue: "core.exec")
    public static let filesystem = OperationKind(rawValue: "core.filesystem")
    public static let image = OperationKind(rawValue: "core.image")
    public static let metadata = OperationKind(rawValue: "core.metadata")
    public static let mount = OperationKind(rawValue: "core.mount")
}

/// Visitor pattern for operation traversal.
///
/// Design rationale:
/// - Type-safe traversal without casting
/// - Extensible for new operations
/// - Supports both read-only traversal and transformation
public protocol OperationVisitor {
    associatedtype Result

    func visit(_ operation: ExecOperation) throws -> Result
    func visit(_ operation: FilesystemOperation) throws -> Result
    func visit(_ operation: ImageOperation) throws -> Result
    func visit(_ operation: MetadataOperation) throws -> Result

    /// Default handler for unknown operations
    func visitUnknown(_ operation: any Operation) throws -> Result
}

/// Base class for operations providing common functionality.
///
/// Design rationale:
/// - While we prefer protocols, a base class here provides default implementations
/// - Reduces boilerplate for operation implementations
/// - Still allows protocol-based extension
@available(*, unavailable, message: "Use specific operation types instead")
open class BaseOperation: @unchecked Sendable, Operation {
    public var metadata: OperationMetadata

    public init(metadata: OperationMetadata) {
        self.metadata = metadata
    }

    public static var operationKind: OperationKind {
        // This class is unavailable for use, but we need to provide a value
        // for protocol conformance. This should never be called in practice.
        OperationKind(rawValue: "base.unavailable")
    }
    public var operationKind: OperationKind { Self.operationKind }

    public func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visitUnknown(self)
    }
}

// MARK: - Operation Metadata

/// Common metadata that can be attached to any operation.
///
/// Design rationale:
/// - Extensible key-value storage for future needs
/// - Strongly-typed for common attributes
/// - Preserves unknown attributes for forward compatibility
public struct OperationMetadata: Sendable, Hashable {
    /// Human-readable comment/description
    public let comment: String?

    /// Source location (file:line) where this operation was defined
    public let sourceLocation: SourceLocation?

    /// Platform constraints for this operation
    public let platforms: Set<Platform>?

    /// Cache configuration
    public let cacheConfig: CacheConfig?

    /// The retry policy for this specific operation.
    public let retryPolicy: RetryPolicy

    /// Additional attributes
    public let attributes: [String: AttributeValue]

    public init(
        comment: String? = nil,
        sourceLocation: SourceLocation? = nil,
        platforms: Set<Platform>? = nil,
        cacheConfig: CacheConfig? = nil,
        retryPolicy: RetryPolicy = RetryPolicy(maxRetries: 0),
        attributes: [String: AttributeValue] = [:]
    ) {
        self.comment = comment
        self.sourceLocation = sourceLocation
        self.platforms = platforms
        self.cacheConfig = cacheConfig
        self.retryPolicy = retryPolicy
        self.attributes = attributes
    }
}

/// Defines the retry behavior for a failed operation.
public struct RetryPolicy: Sendable, Hashable, Codable {
    /// The maximum number of times to retry the operation. A value of 0 means no retries.
    public let maxRetries: Int

    /// The multiplier to apply to the delay between retries. A value of 1.0 is a linear backoff.
    public let backoffMultiplier: Double

    /// The initial delay to wait before the first retry.
    public let initialDelay: TimeInterval

    /// The maximum possible delay between retries.
    public let maxDelay: TimeInterval

    public init(
        maxRetries: Int = 3,
        backoffMultiplier: Double = 2.0,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0
    ) {
        self.maxRetries = maxRetries
        self.backoffMultiplier = backoffMultiplier
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }
}

// MARK: - Operation Extensions

extension Operation {
    /// Compute a content digest for cache key generation using stable serialization
    /// - Throws: OperationError if encoding or digest computation fails
    public func contentDigest() throws -> Digest {
        var hasher = SHA256()

        // For now, use a simple string representation of the operation
        // In production, this would need proper type-specific hashing
        let operationString = String(describing: self)
        guard let operationData = operationString.data(using: String.Encoding.utf8) else {
            // This should never happen as String descriptions are valid UTF-8
            throw OperationError.encodingFailed("Failed to encode operation string as UTF-8: \(operationString)")
        }
        hasher.update(data: operationData)

        let digest = hasher.finalize()
        do {
            return try Digest(algorithm: .sha256, bytes: Data(digest))
        } catch {
            // This should never happen as SHA256 produces correct byte length
            throw OperationError.digestComputationFailed(error)
        }
    }
}

/// Source location information.
public struct SourceLocation: Sendable, Hashable {
    public let file: String
    public let line: Int
    public let column: Int?

    public init(file: String, line: Int, column: Int? = nil) {
        self.file = file
        self.line = line
        self.column = column
    }
}

/// Cache configuration for operations.
public struct CacheConfig: Sendable, Hashable {
    public enum CacheMode: String, Sendable, Hashable {
        case `default`
        case none
        case locked
        case shared
    }

    public let mode: CacheMode
    public let id: String?
    public let sharing: SharingMode?

    public init(mode: CacheMode = .default, id: String? = nil, sharing: SharingMode? = nil) {
        self.mode = mode
        self.id = id
        self.sharing = sharing
    }
}

/// Cache sharing mode.
public enum SharingMode: String, Sendable, Hashable {
    case locked
    case shared
    case `private`
}

/// Attribute value for extensible metadata.
public enum AttributeValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case data(Data)
    case array([AttributeValue])
    case dictionary([String: AttributeValue])
}

// MARK: - Codable Support

extension OperationKind: Codable {}

extension OperationMetadata: Codable {
    // Implementation would handle encoding/decoding of all fields
}

extension SourceLocation: Codable {}

extension CacheConfig.CacheMode: Codable {}
extension CacheConfig: Codable {}

extension SharingMode: Codable {}

extension AttributeValue: Codable {
    // Implementation would handle all cases
}
