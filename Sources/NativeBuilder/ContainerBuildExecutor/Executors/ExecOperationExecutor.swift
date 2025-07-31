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
        do {
            // Stub implementation
            // In a real implementation, this would:
            // 1. Prepare the container environment
            // 2. Execute the command
            // 3. Capture output and changes
            // 4. Update the snapshot

            let startTime = Date()

            // Simulate command execution
            let commandString = execOp.command.displayString
            let output = ExecutionOutput(
                stdout: "Executing: \(commandString)\nOutput from command execution...\nDone.",
                stderr: "",
                exitCode: 0
            )

            // Simulate filesystem changes
            let changes = ContainerBuildSnapshotter.FilesystemChanges(
                added: ["/tmp/exec-\(UUID().uuidString)"],
                sizeChange: 1024
            )

            // Create a new snapshot
            let snapshot = try ContainerBuildSnapshotter.Snapshot(
                digest: Digest(algorithm: .sha256, bytes: Data(count: 32)),
                size: 1024,
                parent: context.latestSnapshot()?.id
            )

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                filesystemChanges: changes,
                environmentChanges: [:],
                metadataChanges: [:],
                snapshot: snapshot,
                duration: duration,
                output: output
            )
        } catch {
            // Collect diagnostics
            let environment = context.environment.effectiveEnvironment

            let diagnostics = ExecutorError.Diagnostics(
                environment: environment,
                workingDirectory: context.workingDirectory,
                recentLogs: ["Failed to execute: \(execOp.command.displayString)"]
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

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        operation is ExecOperation
    }
}
