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

import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerBuildIR

struct BasicTests {

    @Test func digestCreation() throws {
        // Test creating digest from bytes
        let bytes = Data(repeating: 0xAB, count: 32)
        let digest = try Digest(algorithm: .sha256, bytes: bytes)
        #expect(digest.algorithm == .sha256)
        #expect(digest.bytes == bytes)

        // Test parsing digest string
        let digestString = "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let parsed = try Digest(parsing: digestString)
        #expect(parsed.stringValue == digestString)

        // Test invalid length
        #expect(throws: Error.self) {
            try Digest(algorithm: .sha256, bytes: Data(count: 16))
        }
    }

    @Test func imageReference() throws {
        // Test parsing various formats
        let refs = [
            ("ubuntu", "ubuntu:latest"),
            ("ubuntu:20.04", "ubuntu:20.04"),
            ("ghcr.io/owner/repo:tag", "ghcr.io/owner/repo:tag"),
            ("localhost:5000/test", "localhost:5000/test:latest"),
            ("image@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "image@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"),
        ]

        for (input, expected) in refs {
            guard let ref = ImageReference(parsing: input) else {
                Issue.record("Failed to parse: \(input)")
                continue
            }
            #expect(ref.stringValue == expected, "Failed for input: \(input)")
        }

        // Test creation
        let ref = try ImageReference(
            registry: "docker.io",
            repository: "library/nginx",
            tag: "alpine"
        )
        #expect(ref.stringValue == "docker.io/library/nginx:alpine")
    }

    @Test func simpleGraph() throws {
        // Create a simple graph
        guard let imageRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }
        let graph = try GraphBuilder.singleStage(
            from: imageRef
        ) { builder in
            try builder
                .run("apk add --no-cache curl")
                .workdir("/app")
                .copyFromContext(paths: ["main.go"], to: "/app/")
                .run("go build -o app main.go")
                .entrypoint(.exec(["/app/app"]))
        }

        #expect(graph.stages.count == 1)
        #expect(graph.stages[0].nodes.count == 5)

        // Validate the graph
        let validator = StandardValidator()
        let result = validator.validate(graph)
        #expect(result.isValid == true, "Graph validation failed: \(result.errors)")
    }

    @Test func multiStageGraph() throws {
        guard let golangRef = ImageReference(parsing: "golang:1.21"),
            let alpineRef = ImageReference(parsing: "alpine:latest")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            // Build stage
            try builder
                .stage(name: "builder", from: golangRef)
                .workdir("/src")
                .copyFromContext(paths: ["go.mod", "go.sum", "*.go"], to: "./")
                .run("go build -o /app")

            // Runtime stage
            try builder
                .stage(from: alpineRef)
                .run("apk add --no-cache ca-certificates")
                .copyFromStage(.named("builder"), paths: ["/app"], to: "/usr/local/bin/app")
                .user(.uid(1000))
                .entrypoint(Command.exec(["/usr/local/bin/app"]))
        }

        #expect(graph.stages.count == 2)
        #expect(graph.stages[0].name == "builder")
        #expect(graph.stages[1].name == nil)

        // Check stage dependencies
        let deps = graph.stages[1].stageDependencies()
        #expect(deps.contains(.named("builder")) == true)
    }

    @Test func operationTypes() throws {
        // Test ExecOperation
        let execOp = ExecOperation(
            command: .shell("echo 'Hello, World!'"),
            environment: Environment([
                (key: "FOO", value: .literal("bar"))
            ]),
            workingDirectory: "/tmp"
        )
        #expect(execOp.command.displayString == "echo 'Hello, World!'")
        #expect(execOp.environment.effectiveEnvironment["FOO"] == "bar")

        // Test FilesystemOperation
        let fsOp = FilesystemOperation(
            action: .copy,
            source: .context(ContextSource(paths: ["file.txt"])),
            destination: "/app/file.txt",
            fileMetadata: FileMetadata(
                ownership: Ownership(user: .numeric(id: 1000), group: .numeric(id: 1000)),
                permissions: .mode(0o644)
            )
        )
        #expect(fsOp.action == .copy)
        #expect(fsOp.destination == "/app/file.txt")

        // Test MetadataOperation
        let metaOp = MetadataOperation(
            action: .setLabel(key: "version", value: "1.0.0")
        )
        if case .setLabel(let key, let value) = metaOp.action {
            #expect(key == "version")
            #expect(value == "1.0.0")
        } else {
            Issue.record("Wrong metadata action type")
        }
    }

    @Test func serialization() throws {
        // Create a graph using the builder
        guard let imageRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let originalGraph = try GraphBuilder.singleStage(
            from: imageRef,
            platform: .linuxAMD64
        ) { builder in
            try builder
                .run("apt-get update && apt-get install -y curl")
                .workdir("/app")
                .copyFromContext(paths: ["package.json", "src/"], to: "/app/")
                .run("npm install")
                .env("NODE_ENV", "production")
                .expose(3000)
                .cmd(Command.exec(["node", "src/index.js"]))
        }

        // Serialize to JSON
        let coder = JSONIRCoder(prettyPrint: true)
        let data = try coder.encode(originalGraph)

        // Deserialize
        let decodedGraph = try coder.decode(data)

        // Compare
        #expect(originalGraph.stages.count == decodedGraph.stages.count)
        #expect(originalGraph.buildArgs == decodedGraph.buildArgs)
        #expect(originalGraph.targetPlatforms == decodedGraph.targetPlatforms)
    }

    @Test func validation() throws {
        // Create a graph with issues
        guard let ubuntuRef = ImageReference(parsing: "ubuntu") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let builder = GraphBuilder()
        try builder
            .stage(from: ubuntuRef)
            .run("apt-get update")  // Warning: update without install
            .copyFromStage(.named("nonexistent"), paths: ["/file"], to: "/")  // Error: stage doesn't exist

        // GraphBuilder should throw validation errors during build
        #expect(throws: ValidationError.self) {
            try builder.build()
        }
    }

    @Test func semanticAnalysis() throws {
        // Create a Python build graph inline
        let graph = try BuildGraph(
            stages: [
                // Dependencies stage
                BuildStage(
                    name: "dependencies",
                    base: ImageOperation(
                        source: .registry(ImageReference(parsing: "python:3.11-slim")!),
                        platform: .linuxAMD64
                    ),
                    nodes: [
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setWorkdir(path: "/app")
                            )
                        ),
                        BuildNode(
                            operation: FilesystemOperation(
                                action: .copy,
                                source: .context(ContextSource(paths: ["requirements.txt"])),
                                destination: "/app/"
                            )
                        ),
                        BuildNode(
                            operation: ExecOperation(
                                command: .shell("pip install --user --no-cache-dir -r requirements.txt")
                            )
                        ),
                    ]
                ),

                // Application stage
                BuildStage(
                    name: "app",
                    base: ImageOperation(
                        source: .registry(ImageReference(parsing: "python:3.11-slim")!),
                        platform: .linuxAMD64
                    ),
                    nodes: [
                        BuildNode(
                            operation: FilesystemOperation(
                                action: .copy,
                                source: .stage(.named("dependencies"), paths: ["/root/.local"]),
                                destination: "/root/.local"
                            )
                        ),
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setUser(user: .uidGid(uid: 1000, gid: 1000))
                            )
                        ),
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setCmd(command: .exec(["python", "main.py"]))
                            )
                        ),
                    ]
                ),
            ],
            targetPlatforms: [.linuxAMD64, .linuxARM64]
        )

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)
        let analyzedGraph = try analyzer.analyze(graph, context: context)

        // SemanticAnalyzer should return the graph unchanged
        #expect(analyzedGraph.stages.count == graph.stages.count)
        #expect(analyzedGraph.buildArgs.count == graph.buildArgs.count)
    }

    @Test func graphTraversal() throws {
        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .scratch),
            nodes: [
                BuildNode(id: UUID(), operation: MetadataOperation(action: .setWorkdir(path: "/app")), dependencies: []),
                BuildNode(id: UUID(), operation: ExecOperation(command: .shell("echo test")), dependencies: []),
                BuildNode(id: UUID(), operation: MetadataOperation(action: .setUser(user: .uid(1000))), dependencies: []),
            ]
        )

        // Test topological sort
        let sorted = try GraphTraversal.topologicalSort(stage)
        #expect(sorted.count == stage.nodes.count)

        // Test finding roots
        let roots = GraphTraversal.findRoots(in: stage)
        #expect(roots.count == 3)  // All nodes are roots in this case

        // Test finding leaves
        let leaves = GraphTraversal.findLeaves(in: stage)
        #expect(leaves.count == 3)  // All nodes are leaves in this case
    }
}
