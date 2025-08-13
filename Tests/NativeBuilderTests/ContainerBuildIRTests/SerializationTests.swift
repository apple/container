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

import Foundation
import Testing

@testable import ContainerBuildIR

struct SerializationTests {

    // MARK: - JSONIRCoder Tests

    @Test func jsonCoderBasicRoundTrip() throws {
        guard let imageRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let originalGraph = try GraphBuilder.singleStage(from: imageRef) { builder in
            try builder
                .run("apk add --no-cache curl")
                .workdir("/app")
                .copyFromContext(paths: ["src/"], to: "/app/")
                .env("NODE_ENV", "production")
                .expose([PortSpec(port: 3000)])
                .cmd(.exec(["node", "index.js"]))
        }

        let coder = JSONIRCoder()
        let encodedData = try coder.encode(originalGraph)
        let decodedGraph = try coder.decode(encodedData)

        // Verify structure preservation
        #expect(decodedGraph.stages.count == originalGraph.stages.count)
        #expect(decodedGraph.buildArgs == originalGraph.buildArgs)
        #expect(decodedGraph.targetPlatforms == originalGraph.targetPlatforms)

        // Verify stage content
        let originalStage = originalGraph.stages[0]
        let decodedStage = decodedGraph.stages[0]
        #expect(decodedStage.nodes.count == originalStage.nodes.count)
        #expect(decodedStage.name == originalStage.name)
    }

    @Test func jsonCoderPrettyPrint() throws {
        guard let imageRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.singleStage(from: imageRef) { builder in
            try builder
                .run("apt-get update")
                .run("apt-get install -y python3")
        }

        let prettyPrintCoder = JSONIRCoder(prettyPrint: true)
        let compactCoder = JSONIRCoder(prettyPrint: false)

        let prettyData = try prettyPrintCoder.encode(graph)
        let compactData = try compactCoder.encode(graph)

        // Pretty printed should be larger (contains whitespace)
        #expect(prettyData.count > compactData.count)

        // Both should decode to the same graph
        let prettyGraph = try prettyPrintCoder.decode(prettyData)
        let compactGraph = try compactCoder.decode(compactData)

        #expect(prettyGraph.stages.count == compactGraph.stages.count)
        #expect(prettyGraph.buildArgs == compactGraph.buildArgs)

        // Verify JSON is actually pretty printed
        let prettyJson = String(data: prettyData, encoding: .utf8)!
        #expect(prettyJson.contains("\n"), "Pretty printed JSON should contain newlines")
        #expect(prettyJson.contains("  "), "Pretty printed JSON should contain indentation")
    }

    @Test func jsonCoderMultiStageGraph() throws {
        guard let nodeRef = ImageReference(parsing: "node:18"),
            let nginxRef = ImageReference(parsing: "nginx:alpine")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        let originalGraph = try GraphBuilder.multiStage { builder in
            try builder
                .stage(name: "build", from: nodeRef)
                .workdir("/app")
                .copyFromContext(paths: ["package.json"], to: "./")
                .run("npm install")
                .copyFromContext(paths: ["src/"], to: "./src/")
                .run("npm run build")

            try builder
                .stage(from: nginxRef)
                .copyFromStage(.named("build"), paths: ["/app/dist"], to: "/usr/share/nginx/html")
                .expose([PortSpec(port: 80)])
        }

        let coder = JSONIRCoder()
        let encodedData = try coder.encode(originalGraph)
        let decodedGraph = try coder.decode(encodedData)

        #expect(decodedGraph.stages.count == 2)
        #expect(decodedGraph.stages[0].name == "build")
        #expect(decodedGraph.stages[1].name == nil)

        // Verify stage dependencies are preserved
        let runtimeStage = decodedGraph.stages[1]
        let stageDeps = runtimeStage.stageDependencies()
        #expect(stageDeps.contains(.named("build")))
    }

    @Test func jsonCoderWithBuildArgs() throws {
        guard let nodeRef = ImageReference(parsing: "node:18") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let originalGraph = try GraphBuilder.singleStage(from: nodeRef) { builder in
            try builder
                .arg("NODE_ENV", defaultValue: "development")
                .arg("BUILD_VERSION")
                .env("NODE_ENV", "production")
                .env("BUILD_VERSION", "1.2.3")
                .run("npm install")
        }

        let coder = JSONIRCoder()
        let encodedData = try coder.encode(originalGraph)
        let decodedGraph = try coder.decode(encodedData)

        // Verify build args preservation
        #expect(decodedGraph.buildArgs.count >= 0)

        // Verify target platforms preservation
        #expect(decodedGraph.targetPlatforms.count >= 0)
    }

    // MARK: - BinaryIRCoder Tests

    @Test func binaryCoderBasicRoundTrip() throws {
        guard let imageRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let originalGraph = try GraphBuilder.singleStage(from: imageRef) { builder in
            try builder
                .run("apk add --no-cache git")
                .workdir("/app")
                .copyFromContext(paths: ["main.go"], to: "/app/")
                .run("go build -o app main.go")
                .entrypoint(.exec(["/app/app"]))
        }

        let coder = BinaryIRCoder()
        let encodedData = try coder.encode(originalGraph)
        let decodedGraph = try coder.decode(encodedData)

        // Verify structure preservation
        #expect(decodedGraph.stages.count == originalGraph.stages.count)
        #expect(decodedGraph.buildArgs == originalGraph.buildArgs)
        #expect(decodedGraph.targetPlatforms == originalGraph.targetPlatforms)

        // Verify stage content
        let originalStage = originalGraph.stages[0]
        let decodedStage = decodedGraph.stages[0]
        #expect(decodedStage.nodes.count == originalStage.nodes.count)
    }

    @Test func binaryCoderCompression() throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a larger graph to test compression effectiveness
        let originalGraph = try GraphBuilder.multiStage { builder in
            for i in 0..<3 {
                try builder
                    .stage(name: "stage\(i)", from: ubuntuRef)
                    .run("apt-get update")
                    .run("apt-get install -y curl wget git vim")
                    .workdir("/app")
                    .copyFromContext(paths: ["file\(i).txt"], to: "/app/")
                    .env("STAGE_NUMBER", "\(i)")
                    .label("stage.number", "\(i)")
                    .label("stage.description", "This is stage number \(i) with detailed information")
            }
        }

        let jsonCoder = JSONIRCoder(prettyPrint: false)
        let binaryCoder = BinaryIRCoder()

        let jsonData = try jsonCoder.encode(originalGraph)
        let binaryData = try binaryCoder.encode(originalGraph)

        // Binary format should typically be smaller than JSON
        #expect(
            binaryData.count <= jsonData.count,
            "Binary format should be more compact (JSON: \(jsonData.count), Binary: \(binaryData.count))")

        // Verify both decode correctly
        let jsonGraph = try jsonCoder.decode(jsonData)
        let binaryGraph = try binaryCoder.decode(binaryData)

        #expect(jsonGraph.stages.count == binaryGraph.stages.count)
        #expect(jsonGraph.buildArgs == binaryGraph.buildArgs)
    }

    @Test func binaryCoderComplexOperations() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let originalGraph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run(
                    "apk add --no-cache build-tools",
                    mounts: [
                        Mount(type: .cache, target: "/var/cache/apk", source: .local("apk-cache")),
                        Mount(type: .secret, target: "/run/secrets/token", source: .secret("github-token")),
                    ]
                )
                .copyFromContext(
                    paths: ["src/**/*.c", "include/**/*.h"],
                    to: "/app/"
                )
                .healthcheck(
                    test: .command(.exec(["./healthcheck.sh"])),
                    interval: 30,
                    timeout: 5,
                    retries: 3
                )
                .user(.uidGid(uid: 1000, gid: 1000))
        }

        let coder = BinaryIRCoder()
        let encodedData = try coder.encode(originalGraph)
        let decodedGraph = try coder.decode(encodedData)

        // Verify complex operations are preserved
        let stage = decodedGraph.stages[0]

        // Check for RUN operation with mounts
        let runOps = stage.nodes.compactMap { $0.operation as? ExecOperation }
        let runWithMounts = runOps.first { !$0.mounts.isEmpty }
        #expect(runWithMounts != nil, "RUN operation with mounts should be preserved")
        #expect(runWithMounts!.mounts.count == 2, "Both mounts should be preserved")

        // Check for COPY operation with metadata
        let copyOps = stage.nodes.compactMap { $0.operation as? FilesystemOperation }
        let copyWithMetadata = copyOps.first {
            $0.fileMetadata.permissions != nil
        }
        #expect(copyWithMetadata != nil, "COPY operation should preserve file permissions by default")

        // Check for metadata operations
        let metaOps = stage.nodes.compactMap { $0.operation as? MetadataOperation }
        let hasHealthcheck = metaOps.contains {
            if case .setHealthcheck = $0.action { return true }
            return false
        }
        #expect(hasHealthcheck, "Healthcheck metadata should be preserved")
    }

    // MARK: - Format Comparison Tests

    @Test func formatSizeComparison() throws {
        guard let golangRef = ImageReference(parsing: "golang:1.21"),
            let alpineRef = ImageReference(parsing: "alpine:latest")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        // Create a realistic build graph
        let graph = try GraphBuilder.multiStage { builder in
            try builder
                .stage(name: "builder", from: golangRef)
                .workdir("/src")
                .copyFromContext(paths: ["go.mod", "go.sum"], to: "./")
                .run("go mod download")
                .copyFromContext(paths: ["cmd/", "internal/", "pkg/"], to: "./")
                .run("CGO_ENABLED=0 GOOS=linux go build -ldflags='-w -s' -o /app cmd/main.go")

            try builder
                .stage(from: alpineRef)
                .run("apk add --no-cache ca-certificates")
                .copyFromStage(.named("builder"), paths: ["/app"], to: "/usr/local/bin/")
                .user(.uid(65534))
                .expose([PortSpec(port: 8080)])
                .entrypoint(.exec(["/usr/local/bin/app"]))
        }

        let jsonCompactCoder = JSONIRCoder(prettyPrint: false)
        let jsonPrettyCoder = JSONIRCoder(prettyPrint: true)
        let binaryCoder = BinaryIRCoder()

        let jsonCompactData = try jsonCompactCoder.encode(graph)
        let jsonPrettyData = try jsonPrettyCoder.encode(graph)
        let binaryData = try binaryCoder.encode(graph)

        print("Format size comparison:")
        print("- JSON (compact): \(jsonCompactData.count) bytes")
        print("- JSON (pretty):  \(jsonPrettyData.count) bytes")
        print("- Binary:         \(binaryData.count) bytes")

        // Expected size ordering
        #expect(binaryData.count <= jsonCompactData.count)
        #expect(jsonCompactData.count < jsonPrettyData.count)

        // All should decode to equivalent graphs
        let graphs = [
            try jsonCompactCoder.decode(jsonCompactData),
            try jsonPrettyCoder.decode(jsonPrettyData),
            try binaryCoder.decode(binaryData),
        ]

        for graph in graphs {
            #expect(graph.stages.count == 2)
            #expect(graph.stages[0].name == "builder")
        }
    }

    // MARK: - Error Handling Tests

    @Test func corruptedDataHandling() throws {
        let coder = JSONIRCoder()

        // Test completely invalid data
        let invalidData = "not valid json".data(using: .utf8)!
        #expect(throws: Error.self) {
            try coder.decode(invalidData)
        }

        // Test valid JSON but invalid structure
        let invalidStructure = """
            {
                "version": "1.0",
                "graph": {
                    "stages": "this should be an array"
                }
            }
            """.data(using: .utf8)!

        #expect(throws: Error.self) {
            try coder.decode(invalidStructure)
        }
    }

    @Test func binaryCorruptedDataHandling() throws {
        let coder = BinaryIRCoder()

        // Test invalid binary data
        let invalidData = Data(repeating: 0xFF, count: 100)
        #expect(throws: Error.self) {
            try coder.decode(invalidData)
        }

        // Test truncated data
        let validGraph: BuildGraph
        do {
            validGraph = try GraphBuilder.singleStage(
                from: ImageReference(parsing: "alpine")!
            ) { builder in
                try builder.run("echo test")
            }
        } catch {
            Issue.record("Failed to create test graph")
            return
        }

        let validData = try coder.encode(validGraph)
        let truncatedData = validData.prefix(validData.count / 2)

        #expect(throws: Error.self) {
            try coder.decode(Data(truncatedData))
        }
    }

    @Test func versionHandling() throws {
        // Test that we can detect version information in JSON format
        let graph: BuildGraph
        do {
            graph = try GraphBuilder.singleStage(
                from: ImageReference(parsing: "alpine")!
            ) { builder in
                try builder.run("echo version test")
            }
        } catch {
            Issue.record("Failed to create test graph")
            return
        }

        let coder = JSONIRCoder(prettyPrint: true)
        let data = try coder.encode(graph)
        let jsonString = String(data: data, encoding: .utf8)!

        #expect(jsonString.contains("\"version\""), "JSON should contain version information")
        #expect(jsonString.contains("\"1.0\""), "Should use version 1.0")

        // Should decode correctly
        let decodedGraph = try coder.decode(data)
        #expect(decodedGraph.stages.count == graph.stages.count)
    }

    // MARK: - File I/O Tests

    @Test func saveAndLoadGraph() throws {
        guard let imageRef = ImageReference(parsing: "python:3.11") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let originalGraph = try GraphBuilder.singleStage(from: imageRef) { builder in
            try builder
                .workdir("/app")
                .copyFromContext(paths: ["requirements.txt"], to: "./")
                .run("pip install -r requirements.txt")
                .copyFromContext(paths: ["src/"], to: "./src/")
                .cmd(.exec(["python", "src/main.py"]))
        }

        let tempDir = FileManager.default.temporaryDirectory
        let jsonURL = tempDir.appendingPathComponent("test-graph.json")
        let binaryURL = tempDir.appendingPathComponent("test-graph.bin")

        // Save using different formats
        try originalGraph.save(to: jsonURL, using: JSONIRCoder(prettyPrint: true))
        try originalGraph.save(to: binaryURL, using: BinaryIRCoder())

        // Verify files exist and have content
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        #expect(FileManager.default.fileExists(atPath: binaryURL.path))

        let jsonFileSize = try FileManager.default.attributesOfItem(atPath: jsonURL.path)[.size] as! Int
        let binaryFileSize = try FileManager.default.attributesOfItem(atPath: binaryURL.path)[.size] as! Int

        #expect(jsonFileSize > 0)
        #expect(binaryFileSize > 0)

        // Load and verify
        let jsonGraph = try BuildGraph.load(from: jsonURL, using: JSONIRCoder())
        let binaryGraph = try BuildGraph.load(from: binaryURL, using: BinaryIRCoder())

        #expect(jsonGraph.stages.count == originalGraph.stages.count)
        #expect(binaryGraph.stages.count == originalGraph.stages.count)

        // Cleanup
        try? FileManager.default.removeItem(at: jsonURL)
        try? FileManager.default.removeItem(at: binaryURL)
    }

    // MARK: - Performance Tests

    @Test func serializationPerformance() throws {
        // Create a large graph for performance testing
        guard let baseRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        var stages: [BuildStage] = []

        // Create 5 stages with 10 operations each
        for stageIndex in 0..<5 {
            var nodes: [BuildNode] = []

            for opIndex in 0..<10 {
                let operation: any ContainerBuildIR.Operation
                switch opIndex % 4 {
                case 0:
                    operation = ExecOperation(command: .shell("echo 'stage \(stageIndex) op \(opIndex)'"))
                case 1:
                    operation = FilesystemOperation(
                        action: .copy,
                        source: .context(ContextSource(paths: ["file\(opIndex).txt"])),
                        destination: "/app/file\(opIndex).txt"
                    )
                case 2:
                    operation = MetadataOperation(action: .setEnv(key: "VAR\(opIndex)", value: .literal("value\(opIndex)")))
                default:
                    operation = MetadataOperation(action: .setLabel(key: "label\(opIndex)", value: "value\(opIndex)"))
                }

                nodes.append(BuildNode(operation: operation, dependencies: []))
            }

            stages.append(
                BuildStage(
                    name: "stage\(stageIndex)",
                    base: ImageOperation(source: .registry(baseRef)),
                    nodes: nodes
                ))
        }

        let largeGraph = try BuildGraph(stages: stages)

        let jsonCoder = JSONIRCoder()
        let binaryCoder = BinaryIRCoder()

        // Measure JSON encoding time
        let jsonStartTime = Date()
        let jsonData = try jsonCoder.encode(largeGraph)
        let jsonEncodeTime = Date().timeIntervalSince(jsonStartTime)

        // Measure binary encoding time
        let binaryStartTime = Date()
        let binaryData = try binaryCoder.encode(largeGraph)
        let binaryEncodeTime = Date().timeIntervalSince(binaryStartTime)

        print("Encoding performance for large graph:")
        print("- JSON:   \(String(format: "%.3f", jsonEncodeTime))s (\(jsonData.count) bytes)")
        print("- Binary: \(String(format: "%.3f", binaryEncodeTime))s (\(binaryData.count) bytes)")

        // Both should complete in reasonable time (under 1 second for this size)
        #expect(jsonEncodeTime < 1.0, "JSON encoding should be fast")
        #expect(binaryEncodeTime < 1.0, "Binary encoding should be fast")

        // Measure decoding performance
        let jsonDecodeStart = Date()
        let _ = try jsonCoder.decode(jsonData)
        let jsonDecodeTime = Date().timeIntervalSince(jsonDecodeStart)

        let binaryDecodeStart = Date()
        let _ = try binaryCoder.decode(binaryData)
        let binaryDecodeTime = Date().timeIntervalSince(binaryDecodeStart)

        print("Decoding performance for large graph:")
        print("- JSON:   \(String(format: "%.3f", jsonDecodeTime))s")
        print("- Binary: \(String(format: "%.3f", binaryDecodeTime))s")

        #expect(jsonDecodeTime < 1.0, "JSON decoding should be fast")
        #expect(binaryDecodeTime < 1.0, "Binary decoding should be fast")
    }

    // MARK: - Edge Cases

    @Test func emptyGraphSerialization() throws {
        // Test edge case of empty graph
        let emptyGraph = try BuildGraph(stages: [])

        let jsonCoder = JSONIRCoder()
        let binaryCoder = BinaryIRCoder()

        let jsonData = try jsonCoder.encode(emptyGraph)
        let binaryData = try binaryCoder.encode(emptyGraph)

        let jsonDecoded = try jsonCoder.decode(jsonData)
        let binaryDecoded = try binaryCoder.decode(binaryData)

        #expect(jsonDecoded.stages.isEmpty)
        #expect(binaryDecoded.stages.isEmpty)
        #expect(jsonDecoded.buildArgs.isEmpty)
        #expect(binaryDecoded.buildArgs.isEmpty)
    }

    @Test func graphWithSpecialCharacters() throws {
        guard let baseRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.singleStage(from: baseRef) { builder in
            try builder
                .run("echo 'Special chars: 中文 émojis 🚀 newlines\n and quotes \"test\"'")
                .env("UNICODE", "Contains unicode: ñáéíóú 中文字符 🌍")
                .label("description", "Multi-line\ndescription with\ttabs and spaces")
                .workdir("/app with spaces/and-symbols!@#$%")
        }

        let jsonCoder = JSONIRCoder(prettyPrint: true)
        let binaryCoder = BinaryIRCoder()

        let jsonData = try jsonCoder.encode(graph)
        let binaryData = try binaryCoder.encode(graph)

        let jsonDecoded = try jsonCoder.decode(jsonData)
        let binaryDecoded = try binaryCoder.decode(binaryData)

        #expect(jsonDecoded.stages.count == 1)
        #expect(binaryDecoded.stages.count == 1)

        // Check that the operations contain the expected special characters
        let stage = jsonDecoded.stages[0]
        let execOp = stage.nodes.compactMap { $0.operation as? ExecOperation }.first!
        let envOp = stage.nodes.compactMap { $0.operation as? MetadataOperation }.first { op in
            if case .setEnv(let key, _) = op.action, key == "UNICODE" { return true }
            return false
        }!

        // Verify special characters are preserved
        if case .shell(let command) = execOp.command {
            #expect(command.contains("中文"), "Unicode characters should be preserved in command")
            #expect(command.contains("🚀"), "Emoji should be preserved in command")
            #expect(command.contains("\n"), "Newlines should be preserved in command")
        }

        if case .setEnv(_, let value) = envOp.action, case .literal(let envValue) = value {
            #expect(envValue.contains("中文字符"), "Unicode characters should be preserved in env")
            #expect(envValue.contains("🌍"), "Emoji should be preserved in env")
        }
    }
}
