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
import ContainerBuildReporting
import ContainerBuildSnapshotter
import Foundation
import Testing

@testable import ContainerBuildExecutor

struct ExecutionDispatcherTests {

    @Test func dispatcherRouting() async throws {
        // Create test executors with different capabilities
        let execExecutor = ExecOperationExecutor()
        let fsExecutor = FilesystemOperationExecutor()
        let metadataExecutor = MetadataOperationExecutor()

        let dispatcher = ExecutionDispatcher(executors: [
            execExecutor,
            fsExecutor,
            metadataExecutor,
        ])

        // Create test context
        let context = try createTestContext()

        // Test exec operation routing
        let execOp = ExecOperation(
            command: .shell("echo test"),
            environment: .empty,
            mounts: [],
            workingDirectory: nil,
            user: nil,
            network: .default,
            security: .default,
            metadata: OperationMetadata()
        )

        let execResult = try await dispatcher.dispatch(execOp, context: context)
        #expect(execResult.duration > 0)

        // Test filesystem operation routing
        let fsOp = FilesystemOperation(
            action: .copy,
            source: .context(ContextSource(paths: ["test.txt"])),
            destination: "/app/test.txt",
            fileMetadata: FileMetadata(),
            options: FilesystemOptions(),
            metadata: OperationMetadata()
        )

        let fsResult = try await dispatcher.dispatch(fsOp, context: context)
        #expect(fsResult.snapshot != nil)

        // Test metadata operation routing
        let metadataOp = MetadataOperation(
            action: .setEnv(key: "TEST", value: .literal("value")),
            metadata: OperationMetadata()
        )

        let metadataResult = try await dispatcher.dispatch(metadataOp, context: context)
        #expect(metadataResult.environmentChanges["TEST"] == EnvironmentValue.literal("value"))
    }

    @Test func capabilityMatching() async throws {
        // Create a custom executor with specific capabilities
        struct PrivilegedExecutor: OperationExecutor {
            let capabilities = ExecutorCapabilities(
                supportedOperations: [.exec],
                requiresPrivileged: true,
                maxConcurrency: 1
            )

            func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult {
                let digest = try! Digest(algorithm: .sha256, bytes: Data(count: 32))
                let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let snapshot = Snapshot(
                    digest: digest,
                    size: 0,
                    state: .prepared(mountpoint: mountPoint)
                )
                return ExecutionResult(
                    environmentChanges: [:],
                    metadataChanges: [:],
                    snapshot: snapshot,
                    duration: 0.001
                )
            }

            func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
                operation is ExecOperation
            }
        }

        let regularExecutor = ExecOperationExecutor()
        let privilegedExecutor = PrivilegedExecutor()

        let dispatcher = ExecutionDispatcher(executors: [
            regularExecutor,
            privilegedExecutor,
        ])

        let context = try createTestContext()
        let execOp = ExecOperation(
            command: .shell("privileged command"),
            environment: .empty,
            mounts: [],
            workingDirectory: nil,
            user: nil,
            network: .default,
            security: .default,
            metadata: OperationMetadata()
        )

        // Without constraints, should use regular executor
        _ = try await dispatcher.dispatch(execOp, context: context)

        // With privileged constraint, should use privileged executor
        let constraints = NodeConstraints(requiresPrivileged: true)
        _ = try await dispatcher.dispatch(
            execOp,
            context: context,
            constraints: constraints
        )
    }

    @Test func unsupportedOperation() async throws {
        // Create dispatcher with limited executors
        let dispatcher = ExecutionDispatcher(executors: [
            ExecOperationExecutor()
        ])

        let context = try createTestContext()

        // Try to dispatch an unsupported operation
        struct CustomOperation: ContainerBuildIR.Operation {
            static let operationKind = OperationKind(rawValue: "custom")
            var operationKind: OperationKind { Self.operationKind }
            let metadata: OperationMetadata = OperationMetadata()

            func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
                try visitor.visitUnknown(self)
            }
        }

        let customOp = CustomOperation()

        await #expect(throws: (any Error).self) {
            try await dispatcher.dispatch(customOp, context: context)
        }
    }

    @Test func concurrencyLimiting() async throws {
        // Create executor with limited concurrency
        struct SlowExecutor: OperationExecutor {
            let capabilities = ExecutorCapabilities(
                supportedOperations: [.exec],
                maxConcurrency: 2
            )

            func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult {
                // Simulate slow operation
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                let digest = try! Digest(algorithm: .sha256, bytes: Data(count: 32))
                let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let snapshot = Snapshot(
                    digest: digest,
                    size: 0,
                    state: .prepared(mountpoint: mountPoint)
                )
                return ExecutionResult(
                    environmentChanges: [:],
                    metadataChanges: [:],
                    snapshot: snapshot,
                    duration: 0.1
                )
            }

            func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
                operation is ExecOperation
            }
        }

        let dispatcher = ExecutionDispatcher(executors: [SlowExecutor()])
        let context = try createTestContext()

        // Create multiple operations
        let operations = (0..<5).map { i in
            ExecOperation(
                command: .shell("echo \(i)"),
                environment: .empty,
                mounts: [],
                workingDirectory: nil,
                user: nil,
                network: .default,
                security: .default,
                metadata: OperationMetadata()
            )
        }

        // Dispatch all operations concurrently
        let startTime = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for op in operations {
                group.addTask {
                    _ = try await dispatcher.dispatch(op, context: context)
                }
            }
            try await group.waitForAll()
        }
        let duration = Date().timeIntervalSince(startTime)

        // With max concurrency 2 and 5 operations at 100ms each,
        // should take at least 300ms (3 batches)
        #expect(duration > 0.25)
    }

    // MARK: - Helpers

    private func createTestContext() throws -> ExecutionContext {
        let stage = BuildStage(
            id: UUID(),
            name: "test",
            base: ImageOperation(
                source: .scratch,
                platform: nil,
                pullPolicy: .ifNotPresent,
                verification: nil,
                metadata: OperationMetadata()
            ),
            nodes: [],
            platform: nil
        )

        let graph = try BuildGraph(
            stages: [stage],
            buildArgs: [:],
            targetPlatforms: [.linuxAMD64],
            metadata: BuildGraphMetadata()
        )

        let mockSnapshotter = MockSnapshotter()
        return ExecutionContext(
            stage: stage,
            graph: graph,
            platform: .linuxAMD64,
            reporter: Reporter(),
            snapshotter: mockSnapshotter
        )
    }
}
