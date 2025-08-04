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
import Testing

@testable import ContainerBuildParser

@Suite class VisitorTest {
    @Test func simpleVisitFrom() throws {
        let imageName = "alpine"
        let expectedImageRef = ImageReference(parsing: imageName)
        let stageName = "build"
        let platformString = "linux/arm64"
        let expectedPlatform = try Platform(from: platformString)

        let from = try FromInstruction(image: imageName, platform: platformString, stageName: stageName)
        let visitor = DockerInstructionVisitor()
        try visitor.visit(from)

        let graph = try visitor.graphBuilder.build()
        #expect(graph.stages.count == 1)
        let stage = graph.stages[0]
        #expect(stage.name == stageName)
        #expect(stage.platform! == expectedPlatform)
        #expect(stage.base.source == .registry(expectedImageRef!))
    }

    @Test func simpleVisitRun() throws {
        let from = try FromInstruction(image: "scratch")
        let command = ["sh", "-c", "top"]
        let network = "default"
        let run = try RunInstruction(
            command: command,
            shell: false,
            rawMounts: [],
            network: network
        )

        let visitor = DockerInstructionVisitor()
        try visitor.visit(from)
        try visitor.visit(run)

        let graph = try visitor.graphBuilder.build()

        #expect(graph.stages.count == 1)
        let stage = graph.stages[0]

        #expect(stage.nodes.count == 1)
        let node = stage.nodes[0]

        #expect(node.operation is ExecOperation)

        guard let exec = node.operation as? ExecOperation else {
            Issue.record("expected ExecOperation, instead got \(node.operation)")
            return
        }

        #expect(exec.command.arguments == command)
        #expect(exec.mounts.isEmpty)
        #expect(exec.network == .default)
    }

    @Test func simpleVisitCopy() throws {
        let from = try FromInstruction(image: "scratch")
        let sources = ["src", "src1", "src2"]
        let dest = "/dest"
        let copy = try CopyInstruction(
            sources: sources,
            destination: dest,
            from: nil,
            ownership: "10:10",
            permissions: "777"
        )

        let visitor = DockerInstructionVisitor()
        try visitor.visit(from)
        try visitor.visit(copy)

        let graph = try visitor.graphBuilder.build()

        #expect(graph.stages.count == 1)
        let stage = graph.stages[0]

        #expect(stage.nodes.count == 1)
        let node = stage.nodes[0]

        guard let copyNode = node.operation as? FilesystemOperation else {
            Issue.record("expected FilesystemOperation, instead got \(node.operation)")
            return
        }

        #expect(copyNode.action == .copy)

        let expectedSource = ContextSource(
            name: "default",
            paths: sources)
        #expect(copyNode.source == .context(expectedSource))
        #expect(copyNode.destination == dest)

        let expectedOwnership = Ownership(user: .numeric(id: 10), group: .numeric(id: 10))
        #expect(copyNode.fileMetadata.ownership == expectedOwnership)

        let expectedPerms: Permissions = .mode(777)
        #expect(copyNode.fileMetadata.permissions == expectedPerms)
    }
}
