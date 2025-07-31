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
import Testing

@testable import ContainerBuildExecutor

struct SimpleExecutorTests {

    @Test func simpleBuildExecution() async throws {
        // Create a simple build graph
        let imageRef = ImageReference(parsing: "ubuntu:22.04")!
        let graph = try GraphBuilder.singleStage(
            from: imageRef,
            platform: .linuxAMD64
        ) { builder in
            try builder
                .run("apt-get update")
                .run("apt-get install -y curl")
                .workdir("/app")
                .copy(from: .context(ContextSource(paths: ["main.go"])), to: "/app/")
                .run("go build -o app main.go")
                .cmd(Command.exec(["./app"]))
        }

        // Create executor (using Scheduler as the main executor)
        let executor = Scheduler()

        // Execute the build
        let result = try await executor.execute(graph)

        // Verify results
        #expect(result.manifests.count == 1)
        #expect(result.manifests[.linuxAMD64] != nil)
        #expect(result.metrics.operationCount > 0)
        #expect(result.metrics.totalDuration >= 0)
    }

    @Test func multiStageBuildExecution() async throws {
        // Create a multi-stage build
        let builderImageRef = ImageReference(parsing: "golang:1.21")!
        let alpineImageRef = ImageReference(parsing: "alpine:latest")!
        let graph = try GraphBuilder.multiStage { builder in
            // Build stage
            try builder
                .stage(name: "builder", from: builderImageRef)
                .workdir("/src")
                .copy(from: .context(ContextSource(paths: ["go.mod", "go.sum"])), to: "./")
                .run("go mod download")
                .copy(from: .context(ContextSource(paths: ["*.go"])), to: "./")
                .run("go build -o /app")

            // Runtime stage
            try builder
                .stage(from: alpineImageRef)
                .copy(from: .stage(.named("builder"), paths: ["/app"]), to: "/usr/local/bin/")
                .entrypoint(Command.exec(["/usr/local/bin/app"]))
        }

        let executor = Scheduler()
        let result = try await executor.execute(graph)

        #expect(result.manifests.count == 1)
        #expect(result.metrics.operationCount >= 2)
    }

    @Test func cancellation() async throws {
        // Create a graph with many operations
        let imageRef = ImageReference(parsing: "ubuntu:22.04")!
        let graph = try GraphBuilder.singleStage(
            from: imageRef
        ) { builder in
            for i in 0..<100 {
                try builder.run("echo Step \(i)")
            }
        }

        let executor = Scheduler()

        // Start execution and cancel immediately
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            await executor.cancel()
        }

        await #expect(throws: (any Error).self) {
            try await executor.execute(graph)
        }
    }

    @Test func caching() async throws {
        let cache = MemoryBuildCache()
        let executor = Scheduler(cache: cache)

        let imageRef = ImageReference(parsing: "alpine:latest")!
        let graph = try GraphBuilder.singleStage(
            from: imageRef
        ) { builder in
            try builder.run("echo 'Hello, World!'")
        }

        // First execution
        let result1 = try await executor.execute(graph)
        #expect(result1.metrics.cachedOperationCount == 0)

        // Second execution should use cache
        let result2 = try await executor.execute(graph)
        #expect(result2.metrics.cachedOperationCount > 0)

        // Verify cache stats
        let stats = await cache.statistics()
        #expect(stats.hitRate > 0)
    }

    @Test func executorCapabilities() async throws {
        // Test that operations are routed to correct executors
        let execExecutor = ExecOperationExecutor()
        let fsExecutor = FilesystemOperationExecutor()

        #expect(execExecutor.capabilities.supportedOperations.contains(.exec) == true)
        #expect(fsExecutor.capabilities.supportedOperations.contains(.filesystem) == true)

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

        #expect(execExecutor.canExecute(execOp) == true)
        #expect(fsExecutor.canExecute(execOp) == false)
    }
}
