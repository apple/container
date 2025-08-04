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

import ContainerBuildCache
import ContainerBuildIR
import ContainerizationOCI
import Foundation

/// The main executor responsible for orchestrating container build execution.
///
/// This protocol defines the high-level interface for executing build graphs.
/// Implementations coordinate stage execution, handle caching, and manage build state.
public protocol BuildExecutor: Sendable {
    /// Execute a complete build graph.
    ///
    /// - Parameter graph: The build graph to execute
    /// - Returns: The result of the build execution
    /// - Throws: Any errors encountered during execution
    func execute(_ graph: BuildGraph) async throws -> BuildResult

    /// Cancel any ongoing execution.
    ///
    /// This should gracefully stop execution and clean up resources.
    func cancel() async
}

/// The result of executing a build graph.
public struct BuildResult: Sendable {
    /// The final image manifest for each target platform.
    public let manifests: [Platform: ImageManifest]

    /// Execution metrics for performance analysis.
    public let metrics: ExecutionMetrics

    /// Cache statistics for the build.
    public let cacheStats: CacheStatistics

    /// Logs generated during the build.
    public let logs: [String]?

    public init(
        manifests: [Platform: ImageManifest],
        metrics: ExecutionMetrics,
        cacheStats: CacheStatistics,
        logs: [String]? = nil
    ) {
        self.manifests = manifests
        self.metrics = metrics
        self.cacheStats = cacheStats
        self.logs = logs
    }
}

/// Represents a built container image manifest.
public struct ImageManifest: Sendable {
    /// The content-addressed digest of the image.
    public let digest: Digest

    /// The size of the image in bytes.
    public let size: Int64

    /// The configuration digest.
    public let configDigest: Digest

    /// Layer digests in order.
    public let layers: [LayerDescriptor]

    public init(
        digest: Digest,
        size: Int64,
        configDigest: Digest,
        layers: [LayerDescriptor]
    ) {
        self.digest = digest
        self.size = size
        self.configDigest = configDigest
        self.layers = layers
    }
}

/// Describes a single layer in an image.
public struct LayerDescriptor: Sendable {
    /// The digest of the layer.
    public let digest: Digest

    /// The size of the layer in bytes.
    public let size: Int64

    /// The media type of the layer.
    public let mediaType: String

    public init(digest: Digest, size: Int64, mediaType: String = "application/vnd.oci.image.layer.v1.tar+gzip") {
        self.digest = digest
        self.size = size
        self.mediaType = mediaType
    }
}

/// Metrics collected during build execution.
public struct ExecutionMetrics: Sendable {
    /// Total execution time.
    public let totalDuration: TimeInterval

    /// Time spent on each stage.
    public let stageDurations: [String: TimeInterval]

    /// Number of operations executed.
    public let operationCount: Int

    /// Number of operations that were cached.
    public let cachedOperationCount: Int

    /// Total bytes transferred.
    public let bytesTransferred: Int64

    public init(
        totalDuration: TimeInterval,
        stageDurations: [String: TimeInterval],
        operationCount: Int,
        cachedOperationCount: Int,
        bytesTransferred: Int64
    ) {
        self.totalDuration = totalDuration
        self.stageDurations = stageDurations
        self.operationCount = operationCount
        self.cachedOperationCount = cachedOperationCount
        self.bytesTransferred = bytesTransferred
    }
}

/// Errors that can occur during build execution.
public enum BuildExecutorError: LocalizedError {
    case stageNotFound(String)
    case cyclicDependency
    case operationFailed(ContainerBuildIR.Operation, underlying: Error)
    case cancelled
    case unsupportedOperation(ContainerBuildIR.Operation)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .stageNotFound(let name):
            return "Stage not found: '\(name)'"
        case .cyclicDependency:
            return "Cyclic dependency detected in build graph"
        case .operationFailed(let op, let error):
            return "Operation failed: \(op) - \(error.localizedDescription)"
        case .cancelled:
            return "Build execution was cancelled"
        case .unsupportedOperation(let op):
            return "Unsupported operation: \(type(of: op))"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
