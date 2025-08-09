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
import Foundation

/// Executes FilesystemOperation (COPY and ADD).
public struct FilesystemOperationExecutor: OperationExecutor {
    public let capabilities: ExecutorCapabilities

    public init() {
        self.capabilities = ExecutorCapabilities(
            supportedOperations: [.filesystem],
            maxConcurrency: 10
        )
    }

    public func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult {
        guard let fsOp = operation as? FilesystemOperation else {
            throw ExecutorError(
                type: .invalidConfiguration,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: NSError(domain: "Executor", code: 1),
                    diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }

        let startTime = Date()

        do {
            let (_, finalSnapshot) = try await context.withSnapshot { snapshot in
                try await performFilesystemOperation(fsOp, in: snapshot)
            }

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                snapshot: finalSnapshot,
                duration: duration,
                output: nil
            )

        } catch {

            throw ExecutorError(
                type: .executionFailed,
                context: ExecutorError.ErrorContext(
                    operation: operation,
                    underlyingError: error,
                    diagnostics: ExecutorError.Diagnostics(
                        environment: context.environment.effectiveEnvironment,
                        workingDirectory: context.workingDirectory,
                        recentLogs: ["Failed to execute filesystem operation: \(fsOp.action)"]
                    )
                )
            )
        }
    }

    /// Perform the filesystem operation.
    ///
    /// This simulates filesystem operations for development and testing purposes.
    /// The snapshotter is fully functional and creates real filesystem snapshots,
    /// but the actual file operations are simulated to avoid system dependencies.
    ///
    /// - Parameters:
    ///   - operation: The filesystem operation to perform
    ///   - snapshot: The prepared snapshot with working directory
    private func performFilesystemOperation(
        _ operation: FilesystemOperation,
        in snapshot: Snapshot
    ) async throws {
        // NOTE: The snapshotter is fully operational and creates real filesystem snapshots.
        // We simulate filesystem operations to:
        // 1. Avoid requiring actual file system access during development
        // 2. Enable predictable testing without side effects
        // 3. Allow the build system to run in restricted environments
        //
        // In a production implementation, this would:
        // 1. Get the working directory from the snapshot (already available)
        // 2. Resolve the source (context, stage, URL)
        // 3. Perform actual file operations (copy or add)
        // 4. Apply file metadata (permissions, ownership)
        // 5. Let the snapshotter track filesystem changes (already working)

        // Only COPY and ADD operations are supported for filesystem operations
        switch operation.action {
        case .copy:
            // Simulate COPY operation
            // In production: Copy files from source to destination in the snapshot
            break
        case .add:
            // Simulate ADD operation
            // In production: Add files to the snapshot, with automatic extraction for archives
            break
        default:
            throw ExecutorError(
                type: .unsupportedOperation,
                context: ExecutorError.ErrorContext(
                    operation: operation,
                    underlyingError: NSError(
                        domain: "FilesystemOperationExecutor",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Only COPY and ADD operations are supported. Got: \(operation.action)"]
                    ),
                    diagnostics: ExecutorError.Diagnostics(
                        environment: [:],
                        workingDirectory: "",
                        recentLogs: ["Unsupported filesystem operation: \(operation.action)"]
                    )
                )
            )
        }
    }

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        operation is FilesystemOperation
    }
}
