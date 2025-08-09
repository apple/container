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
import ContainerizationOCI
import Foundation

/// Routes operations to appropriate executors based on capabilities and constraints.
///
/// The dispatcher maintains a registry of executors and matches operations to
/// executors based on operation type, platform requirements, and executor capabilities.
public final class ExecutionDispatcher: Sendable {
    /// Registered executors.
    private let executors: [any OperationExecutor]

    /// Semaphores for concurrency control per executor.
    private let semaphores: [ObjectIdentifier: AsyncSemaphore]

    public init(executors: [any OperationExecutor]) {
        self.executors = executors

        // Create semaphores based on executor capabilities
        var semas: [ObjectIdentifier: AsyncSemaphore] = [:]
        for executor in executors {
            let id = ObjectIdentifier(type(of: executor))
            semas[id] = AsyncSemaphore(value: executor.capabilities.maxConcurrency)
        }
        self.semaphores = semas
    }

    /// Dispatch an operation to an appropriate executor.
    ///
    /// - Parameters:
    ///   - operation: The operation to execute
    ///   - context: The execution context
    ///   - constraints: Any additional constraints from the build node
    /// - Returns: The execution result
    /// - Throws: If no suitable executor is found or execution fails
    public func dispatch(
        _ operation: ContainerBuildIR.Operation,
        context: ExecutionContext,
        constraints: NodeConstraints? = nil
    ) async throws -> ExecutionResult {
        // Find a suitable executor
        guard
            let executor = findExecutor(
                for: operation,
                platform: context.platform,
                constraints: constraints
            )
        else {
            throw BuildExecutorError.unsupportedOperation(operation)
        }

        // Get semaphore for concurrency control
        let executorId = ObjectIdentifier(type(of: executor))
        guard let semaphore = semaphores[executorId] else {
            throw BuildExecutorError.internalError("Semaphore not found for executor \(executorId)")
        }

        // Execute with concurrency limit
        return try await semaphore.withPermit {
            try await executor.execute(operation, context: context)
        }
    }

    /// Find an executor that can handle the given operation.
    private func findExecutor(
        for operation: ContainerBuildIR.Operation,
        platform: Platform,
        constraints: NodeConstraints?
    ) -> (any OperationExecutor)? {
        // Score each executor based on how well it matches
        let candidates = executors.compactMap { executor -> (executor: any OperationExecutor, score: Int)? in
            guard executor.canExecute(operation) else { return nil }

            let capabilities = executor.capabilities
            var score = 0

            // Check operation kind support
            if capabilities.supportedOperations.contains(operation.operationKind) {
                score += 100
            }

            // Check platform support
            if let supportedPlatforms = capabilities.supportedPlatforms {
                guard supportedPlatforms.contains(platform) else {
                    return nil  // Platform not supported
                }
                score += 50
            } else {
                score += 25  // Supports all platforms
            }

            // Check privilege requirements
            if let constraints = constraints, constraints.requiresPrivileged {
                guard capabilities.requiresPrivileged else {
                    return nil  // Cannot satisfy privilege requirement
                }
                score += 10
            }

            // Check resource requirements
            if let constraints = constraints {
                if !satisfiesResourceRequirements(
                    capabilities.resources,
                    constraints: constraints
                ) {
                    return nil
                }
            }

            return (executor, score)
        }

        // Return the highest scoring executor
        return candidates.max(by: { $0.score < $1.score })?.executor
    }

    /// Check if executor resources satisfy constraints.
    private func satisfiesResourceRequirements(
        _ resources: ResourceRequirements,
        constraints: NodeConstraints
    ) -> Bool {
        // Check memory requirements
        if let requiredMemory = constraints.minMemory,
            let availableMemory = resources.minMemory,
            availableMemory < requiredMemory
        {
            return false
        }

        // Check disk requirements
        if let requiredDisk = constraints.minDiskSpace,
            let availableDisk = resources.minDiskSpace,
            availableDisk < requiredDisk
        {
            return false
        }

        // Check CPU architecture
        if let requiredArch = constraints.cpuArchitecture,
            let availableArch = resources.cpuArchitecture,
            availableArch != requiredArch
        {
            return false
        }

        return true
    }
}

/// Constraints that can be applied to node execution.
public struct NodeConstraints: Sendable {
    /// Whether privileged execution is required.
    public let requiresPrivileged: Bool

    /// Minimum memory required.
    public let minMemory: Int64?

    /// Minimum disk space required.
    public let minDiskSpace: Int64?

    /// Required CPU architecture.
    public let cpuArchitecture: String?

    /// Custom constraints.
    public let custom: [String: String]

    public init(
        requiresPrivileged: Bool = false,
        minMemory: Int64? = nil,
        minDiskSpace: Int64? = nil,
        cpuArchitecture: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.requiresPrivileged = requiresPrivileged
        self.minMemory = minMemory
        self.minDiskSpace = minDiskSpace
        self.cpuArchitecture = cpuArchitecture
        self.custom = custom
    }
}

/// A simple async semaphore for concurrency control.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = value
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            permits += 1
        }
    }

    func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
