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

/// Executes FilesystemOperation (COPY, ADD, etc.).
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

        do {
            // Stub implementation
            // In a real implementation, this would:
            // 1. Resolve the source (context, stage, URL)
            // 2. Copy/add/remove files as specified
            // 3. Apply file metadata (permissions, ownership)
            // 4. Update the snapshot

            let startTime = Date()

            // Simulate filesystem changes based on action
            let changes: ContainerBuildSnapshotter.FilesystemChanges
            switch fsOp.action {
            case .copy, .add:
                changes = ContainerBuildSnapshotter.FilesystemChanges(
                    added: [fsOp.destination],
                    sizeChange: 4096
                )
            case .remove:
                changes = ContainerBuildSnapshotter.FilesystemChanges(
                    deleted: [fsOp.destination],
                    sizeChange: -1024
                )
            case .mkdir:
                changes = ContainerBuildSnapshotter.FilesystemChanges(
                    added: [fsOp.destination],
                    sizeChange: 0
                )
            case .symlink, .hardlink:
                changes = ContainerBuildSnapshotter.FilesystemChanges(
                    added: [fsOp.destination],
                    sizeChange: 0
                )
            }

            // Create a new snapshot
            let snapshot = try ContainerBuildSnapshotter.Snapshot(
                digest: Digest(algorithm: .sha256, bytes: Data(count: 32)),
                size: 4096,
                parent: context.latestSnapshot()?.id
            )

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                filesystemChanges: changes,
                snapshot: snapshot,
                duration: duration
            )
        } catch {
            throw ExecutorError(
                type: .executionFailed,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: error, diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }
    }

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        operation is FilesystemOperation
    }
}
