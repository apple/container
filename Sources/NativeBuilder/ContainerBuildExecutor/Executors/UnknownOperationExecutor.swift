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

/// Executes unknown/custom operations using the visitor pattern.
public struct UnknownOperationExecutor: OperationExecutor {
    public let capabilities: ExecutorCapabilities

    public init() {
        self.capabilities = ExecutorCapabilities(
            supportedOperations: [],  // Doesn't declare specific operations
            maxConcurrency: 1  // Conservative default
        )
    }

    public func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult {
        do {
            // This executor handles operations that don't match built-in types
            // In a real implementation, this could:
            // 1. Use a plugin system
            // 2. Delegate to external executors
            // 3. Apply custom logic based on operation metadata

            let startTime = Date()

            // For now, we'll just log and return a no-op result
            print("WARNING: Executing unknown operation type: \(type(of: operation))")
            print("Operation kind: \(operation.operationKind)")

            // Use the existing snapshot
            let snapshot =
                context.headSnapshot
                ?? ContainerBuildSnapshotter.Snapshot(
                    digest: try Digest(algorithm: .sha256, bytes: Data(count: 32)),
                    size: 0,
                    parent: nil,
                    state: .committed()
                )

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                snapshot: snapshot,
                duration: duration,
                output: ExecutionOutput(
                    stdout: "Executed unknown operation: \(operation.operationKind)\n"
                )
            )
        } catch {
            throw ExecutorError(
                type: .executionFailed,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: error, diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }
    }

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        // This executor can handle any operation as a fallback
        // In practice, you might want to check for specific metadata
        // or operation kinds that indicate custom operations
        true
    }
}
