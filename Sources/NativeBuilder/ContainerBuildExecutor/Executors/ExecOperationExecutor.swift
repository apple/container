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

/// Executes ExecOperation (RUN commands).
public struct ExecOperationExecutor: OperationExecutor {
    public let capabilities: ExecutorCapabilities

    public init() {
        self.capabilities = ExecutorCapabilities(
            supportedOperations: [.exec],
            maxConcurrency: 5
        )
    }

    public func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult {
        guard let execOp = operation as? ExecOperation else {
            throw ExecutorError(
                type: .invalidConfiguration,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: NSError(domain: "Executor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported operation"]),
                    diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }

        let startTime = Date()

        do {
            let (output, finalSnapshot) = try await context.withSnapshot { snapshot in
                try await executeCommand(execOp, in: snapshot, context: context)
            }

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                environmentChanges: [:],  // TODO: Extract environment changes from command execution
                metadataChanges: [:],
                snapshot: finalSnapshot,
                duration: duration,
                output: output
            )
        } catch {
            // Collect diagnostics
            let environment = context.environment.effectiveEnvironment
            let diagnostics = ExecutorError.Diagnostics(
                environment: environment,
                workingDirectory: context.workingDirectory,
                recentLogs: ["Failed to execute: \(execOp.command.displayString)", "Error: \(error.localizedDescription)"]
            )

            throw ExecutorError(
                type: .executionFailed,
                context: ExecutorError.ErrorContext(
                    operation: operation,
                    underlyingError: error,
                    diagnostics: diagnostics
                )
            )
        }
    }

    /// Execute a command in the prepared snapshot environment.
    ///
    /// This simulates command execution for development and testing purposes.
    /// The snapshotter is fully functional and creates real filesystem snapshots,
    /// but the actual command execution is simulated to avoid system dependencies.
    ///
    /// - Parameters:
    ///   - operation: The exec operation to perform
    ///   - snapshot: The prepared snapshot with working directory
    ///   - context: The execution context
    /// - Returns: The simulated execution output
    private func executeCommand(
        _ operation: ExecOperation,
        in snapshot: Snapshot,
        context: ExecutionContext
    ) async throws -> ExecutionOutput {

        let commandString = operation.command.displayString

        // Simulate command execution
        // The snapshotter will still properly track any filesystem changes
        // that would result from this operation
        return ExecutionOutput(
            stdout: "[SIMULATED] Executing: \(commandString)\nOutput from command execution...\nDone.",
            stderr: "",
            exitCode: 0
        )
    }

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        operation is ExecOperation
    }
}
