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

import ContainerBuildIR
import ContainerBuildSnapshotter
import ContainerizationOCI
import Foundation

/// Executes individual operations within a build.
///
/// Implementations handle the actual execution of operations, interacting with
/// the container runtime, filesystem, and other system resources.
public protocol OperationExecutor: Sendable {
    /// The capabilities this executor provides.
    var capabilities: ExecutorCapabilities { get }

    /// Execute a single operation.
    ///
    /// - Parameters:
    ///   - operation: The operation to execute
    ///   - context: The execution context containing current state
    /// - Returns: The result of executing the operation
    /// - Throws: Any errors encountered during execution
    func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult

    /// Check if this executor can handle the given operation.
    ///
    /// - Parameter operation: The operation to check
    /// - Returns: true if this executor can handle the operation
    func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool
}

/// Describes the capabilities of an executor.
///
/// Used by the dispatcher to match operations to appropriate executors.
public struct ExecutorCapabilities: Sendable {
    /// The operation kinds this executor can handle.
    public let supportedOperations: Set<OperationKind>

    /// Platform constraints (nil means all platforms).
    public let supportedPlatforms: Set<Platform>?

    /// Whether this executor requires privileged access.
    public let requiresPrivileged: Bool

    /// Maximum concurrent operations this executor can handle.
    public let maxConcurrency: Int

    /// Resource requirements.
    public let resources: ResourceRequirements

    public init(
        supportedOperations: Set<OperationKind>,
        supportedPlatforms: Set<Platform>? = nil,
        requiresPrivileged: Bool = false,
        maxConcurrency: Int = 10,
        resources: ResourceRequirements = .default
    ) {
        self.supportedOperations = supportedOperations
        self.supportedPlatforms = supportedPlatforms
        self.requiresPrivileged = requiresPrivileged
        self.maxConcurrency = maxConcurrency
        self.resources = resources
    }
}

/// Resource requirements for an executor.
public struct ResourceRequirements: Sendable {
    /// Minimum available memory in bytes.
    public let minMemory: Int64?

    /// Minimum available disk space in bytes.
    public let minDiskSpace: Int64?

    /// Required CPU architecture.
    public let cpuArchitecture: String?

    /// Custom requirements.
    public let custom: [String: String]

    public init(
        minMemory: Int64? = nil,
        minDiskSpace: Int64? = nil,
        cpuArchitecture: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.minMemory = minMemory
        self.minDiskSpace = minDiskSpace
        self.cpuArchitecture = cpuArchitecture
        self.custom = custom
    }

    /// Default resource requirements.
    public static let `default` = ResourceRequirements()
}

/// The result of executing an operation.
public struct ExecutionResult: Sendable {
    /// Filesystem changes made by the operation.
    public let filesystemChanges: FilesystemChanges

    /// Environment changes made by the operation.
    public let environmentChanges: [String: EnvironmentValue]

    /// Metadata changes (labels, etc.).
    public let metadataChanges: [String: String]

    /// The snapshot after execution.
    public let snapshot: Snapshot

    /// Execution duration.
    public let duration: TimeInterval

    /// Any output produced.
    public let output: ExecutionOutput?

    public init(
        filesystemChanges: FilesystemChanges = .empty,
        environmentChanges: [String: EnvironmentValue] = [:],
        metadataChanges: [String: String] = [:],
        snapshot: Snapshot,
        duration: TimeInterval,
        output: ExecutionOutput? = nil
    ) {
        self.filesystemChanges = filesystemChanges
        self.environmentChanges = environmentChanges
        self.metadataChanges = metadataChanges
        self.snapshot = snapshot
        self.duration = duration
        self.output = output
    }
}

/// Output from operation execution.
public struct ExecutionOutput: Sendable {
    /// Standard output.
    public let stdout: String

    /// Standard error.
    public let stderr: String

    /// Exit code (for exec operations).
    public let exitCode: Int?

    public init(stdout: String = "", stderr: String = "", exitCode: Int? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}
