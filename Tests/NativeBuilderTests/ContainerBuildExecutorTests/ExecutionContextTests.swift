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

struct ExecutionContextTests {

    @Test func contextStateManagement() async throws {
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

        let context = ExecutionContext(
            stage: stage,
            graph: graph,
            platform: .linuxAMD64,
            reporter: Reporter()
        )

        // Test environment management
        #expect(context.environment.variables.isEmpty == true)

        context.updateEnvironment(["FOO": EnvironmentValue.literal("bar")])
        #expect(context.environment.get("FOO") == EnvironmentValue.literal("bar"))

        // Test working directory
        #expect(context.workingDirectory == "/")
        context.setWorkingDirectory("/app")
        #expect(context.workingDirectory == "/app")

        // Test user
        #expect(context.user == nil)
        let user = User.userGroup(user: "appuser", group: "appgroup")
        context.setUser(user)
        #expect(context.user == user)

        // Test snapshots
        let snapshot = Snapshot(
            digest: try! Digest(algorithm: .sha256, bytes: Data(count: 32)),
            size: 1024
        )
        let nodeId = UUID()
        context.setSnapshot(snapshot, for: nodeId)
        #expect(context.snapshot(for: nodeId)?.id == snapshot.id)
        #expect(context.latestSnapshot() != nil)
    }

    @Test func imageConfigUpdates() async throws {
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

        let context = ExecutionContext(
            stage: stage,
            graph: graph,
            platform: .linuxAMD64,
            reporter: Reporter()
        )

        // Update image config
        context.updateImageConfig { config in
            config.env = ["PATH=/usr/bin"]
            config.cmd = ["echo", "hello"]
            config.workingDir = "/app"
            config.exposedPorts.insert("8080/tcp")
            config.labels["version"] = "1.0"
        }

        let config = context.imageConfig
        #expect(config.env == ["PATH=/usr/bin"])
        #expect(config.cmd == ["echo", "hello"])
        #expect(config.workingDir == "/app")
        #expect(config.exposedPorts.contains("8080/tcp") == true)
        #expect(config.labels["version"] == "1.0")
    }

    @Test func childContext() async throws {
        let stage1 = BuildStage(
            id: UUID(),
            name: "stage1",
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

        let stage2 = BuildStage(
            id: UUID(),
            name: "stage2",
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
            stages: [stage1, stage2],
            buildArgs: [:],
            targetPlatforms: [.linuxAMD64],
            metadata: BuildGraphMetadata()
        )

        let parentContext = ExecutionContext(
            stage: stage1,
            graph: graph,
            platform: .linuxAMD64,
            reporter: Reporter()
        )

        // Set up parent context
        parentContext.updateEnvironment(["PARENT": EnvironmentValue.literal("value")])
        parentContext.setWorkingDirectory("/parent")

        // Create child context
        let childContext = parentContext.childContext(for: stage2)

        // Child should inherit environment
        #expect(childContext.environment.get("PARENT") == EnvironmentValue.literal("value"))

        // But modifications to child don't affect parent
        childContext.updateEnvironment(["CHILD": EnvironmentValue.literal("value")])
        #expect(parentContext.environment.get("CHILD") == nil)
        #expect(childContext.environment.get("CHILD") == EnvironmentValue.literal("value"))
    }
}
