//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

@Suite(.serialized)
struct TestCLIBuilderLocalOutputSerial {
    @Test func testBuildLocalOutputHappyPath() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                // Comprehensive multi-stage build with context and build args.
                let dir = try f.createTempDir()
                let dockerfile =
                    """
                    ARG MESSAGE=default
                    FROM scratch AS builder
                    ADD build.txt /build.txt
                    ADD testfile.txt /hello.txt
                    FROM scratch
                    COPY --from=builder /build.txt /final.txt
                    COPY --from=builder /hello.txt /app/hello.txt
                    ADD message.txt /message.txt
                    """
                let context: [ContainerFixture.FileSystemEntry] = [
                    .file("build.txt", content: .data("Building stage\n".data(using: .utf8)!)),
                    .file("testfile.txt", content: .data("Hello from local build\n".data(using: .utf8)!)),
                    .file("message.txt", content: .data("Hello from build args\n".data(using: .utf8)!)),
                ]
                try f.createContext(dir: dir, dockerfile: dockerfile, context: context)
                let outputDir = dir.appending("comprehensive-local-output")
                let imageName = "local-comprehensive-test:\(UUID().uuidString)"
                let response = try f.buildWithPathsAndLocalOutput(
                    tag: imageName, contextDir: dir, outputDir: outputDir,
                    buildArgs: ["MESSAGE=Hello from build args"])
                #expect(response.contains(outputDir.string), "output should reference the export path")
                #expect(FileManager.default.fileExists(atPath: outputDir.string))
                let contents = try FileManager.default.contentsOfDirectory(atPath: outputDir.string)
                #expect(!contents.isEmpty, "output directory should contain files")

                // Basic local output.
                let basicDir = try f.createTempDir()
                try f.createContext(
                    dir: basicDir,
                    dockerfile: "FROM scratch\nADD testfile.txt /hello.txt",
                    context: [.file("testfile.txt", content: .data("Hello from basic build\n".data(using: .utf8)!))])
                let basicOutputDir = basicDir.appending("basic-local-output")
                let basicResponse = try f.buildWithPathsAndLocalOutput(
                    tag: "local-basic-test:\(UUID().uuidString)", contextDir: basicDir, outputDir: basicOutputDir)
                #expect(basicResponse.contains(basicOutputDir.string))
                #expect(FileManager.default.fileExists(atPath: basicOutputDir.string))

                // Build with context (COPY instruction).
                let ctxDir = try f.createTempDir()
                try f.createContext(
                    dir: ctxDir,
                    dockerfile: "FROM scratch\nCOPY testfile.txt /app/testfile.txt",
                    context: [.file("testfile.txt", content: .data("Test content\n".data(using: .utf8)!))])
                let ctxOutputDir = ctxDir.appending("context-local-output")
                let ctxResponse = try f.buildWithPathsAndLocalOutput(
                    tag: "local-context-test:\(UUID().uuidString)", contextDir: ctxDir, outputDir: ctxOutputDir)
                #expect(ctxResponse.contains(ctxOutputDir.string))
                #expect(FileManager.default.fileExists(atPath: ctxOutputDir.string))
            }
        }
    }

    @Test func testBuildLocalOutputEdgeCases() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                // Different paths for Dockerfile context and build context.
                let dockerfileDir = try f.createTempDir()
                try f.createContext(
                    dir: dockerfileDir,
                    dockerfile: "FROM scratch\nCOPY . /app",
                    context: [.file("dockerfile-context.txt", content: .data("Dockerfile context\n".data(using: .utf8)!))])

                let buildContextDir = try f.createTempDir()
                try f.createContext(
                    dir: buildContextDir, dockerfile: "",
                    context: [.file("build-context.txt", content: .data("Build context\n".data(using: .utf8)!))])

                let outputDir = dockerfileDir.appending("diffpaths-local-output")
                let response = try f.buildWithPathsAndLocalOutput(
                    tag: "local-diffpaths-test:\(UUID().uuidString)",
                    contextDir: buildContextDir,
                    dockerfilePath: dockerfileDir.appending("Dockerfile"),
                    outputDir: outputDir)
                #expect(response.contains(outputDir.string))
                #expect(FileManager.default.fileExists(atPath: outputDir.string))

                // Build into an existing output directory (should merge/overwrite).
                let existingDir = try f.createTempDir()
                try f.createContext(
                    dir: existingDir,
                    dockerfile: "FROM scratch\nADD newfile.txt /newfile.txt",
                    context: [.file("newfile.txt", content: .data("New content\n".data(using: .utf8)!))])
                let existingOutputDir = existingDir.appending("existing-output")
                try FileManager.default.createDirectory(
                    atPath: existingOutputDir.string, withIntermediateDirectories: true, attributes: nil)
                try "Existing content\n".data(using: .utf8)!
                    .write(to: URL(filePath: existingOutputDir.appending("existing.txt").string), options: .atomic)
                let existingResponse = try f.buildWithPathsAndLocalOutput(
                    tag: "local-existing-test:\(UUID().uuidString)",
                    contextDir: existingDir, outputDir: existingOutputDir)
                #expect(existingResponse.contains(existingOutputDir.string))
                let contents = try FileManager.default.contentsOfDirectory(atPath: existingOutputDir.string)
                #expect(!contents.isEmpty)
            }
        }
    }

    @Test func testBuildLocalOutputFailure() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD test.txt /test.txt",
                    context: [.file("test.txt", content: .data("test\n".data(using: .utf8)!))])

                // An uncreateable path should cause the build to fail.
                let result = try f.run([
                    "build",
                    "-f", dir.appending("Dockerfile").string,
                    "-t", "local-invalid-test:\(UUID().uuidString)",
                    "--output", "type=local,dest=/nonexistent/invalid/path",
                    dir.appending("context").string,
                ])
                #expect(result.status != 0, "build with invalid output path should fail")
            }
        }
    }
}
