//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

extension TestCLIBuildBase {
    class CLIBuilderLocalOutputTest: TestCLIBuildBase {
        override init() throws {
            try super.init()
        }

        deinit {
            try? builderDelete(force: true)
        }

        @Test func testBuildLocalOutputHappyPath() throws {
            let tempDir: URL = try createTempDir()

            // Test comprehensive multi-stage build with context and build arguments
            let dockerfile: String =
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
            let context: [FileSystemEntry] = [
                .file("build.txt", content: .data("Building stage\n".data(using: .utf8)!)),
                .file("testfile.txt", content: .data("Hello from local build\n".data(using: .utf8)!)),
                .file("message.txt", content: .data("Hello from build args\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let outputDir = tempDir.appendingPathComponent("comprehensive-local-output")
            let imageName = "local-comprehensive-test:\(UUID().uuidString)"

            let response = try buildWithLocalOutput(
                tag: imageName,
                tempDir: tempDir,
                outputDir: outputDir,
                args: ["MESSAGE=Hello from build args"]
            )

            // Verify the build succeeded
            #expect(response.contains("Successfully exported to"), "Expected successful local export message")

            // Verify the output directory was created
            #expect(FileManager.default.fileExists(atPath: outputDir.path), "Expected local output directory to exist")

            // Verify the output contains expected structure
            let contents = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
            #expect(!contents.isEmpty, "Expected local output directory to contain files")

            // Test basic functionality - verify basic local output works
            let basicTempDir: URL = try createTempDir()
            let basicDockerfile: String =
                """
                FROM scratch

                ADD testfile.txt /hello.txt
                """
            let basicContext: [FileSystemEntry] = [
                .file("testfile.txt", content: .data("Hello from basic build\n".data(using: .utf8)!))
            ]
            try createContext(tempDir: basicTempDir, dockerfile: basicDockerfile, context: basicContext)

            let basicOutputDir = basicTempDir.appendingPathComponent("basic-local-output")
            let basicImageName = "local-basic-test:\(UUID().uuidString)"

            let basicResponse = try buildWithLocalOutput(tag: basicImageName, tempDir: basicTempDir, outputDir: basicOutputDir)

            // Verify basic build succeeded
            #expect(basicResponse.contains("Successfully exported to"), "Expected successful basic local export message")
            #expect(FileManager.default.fileExists(atPath: basicOutputDir.path), "Expected basic local output directory to exist")

            // Test context functionality - verify COPY works with context
            let contextTempDir: URL = try createTempDir()
            let contextDockerfile: String =
                """
                FROM scratch

                COPY testfile.txt /app/testfile.txt
                """
            let contextContext: [FileSystemEntry] = [
                .file("testfile.txt", content: .data("Test content for context build\n".data(using: .utf8)!))
            ]
            try createContext(tempDir: contextTempDir, dockerfile: contextDockerfile, context: contextContext)

            let contextOutputDir = contextTempDir.appendingPathComponent("context-local-output")
            let contextImageName = "local-context-test:\(UUID().uuidString)"

            let contextResponse = try buildWithLocalOutput(tag: contextImageName, tempDir: contextTempDir, outputDir: contextOutputDir)

            // Verify context build succeeded
            #expect(contextResponse.contains("Successfully exported to"), "Expected successful context local export message")
            #expect(FileManager.default.fileExists(atPath: contextOutputDir.path), "Expected context local output directory to exist")
        }

        @Test func testBuildLocalOutputEdgeCases() throws {
            // Test building with different context paths
            let dockerfileCtxDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch

                COPY . /app
                """
            let dockerfileCtx: [FileSystemEntry] = [
                .file("dockerfile-context.txt", content: .data("Dockerfile context file\n".data(using: .utf8)!))
            ]
            try createContext(tempDir: dockerfileCtxDir, dockerfile: dockerfile, context: dockerfileCtx)

            let buildContextDir: URL = try createTempDir()
            let buildContext: [FileSystemEntry] = [
                .file("build-context.txt", content: .data("Build context file\n".data(using: .utf8)!))
            ]
            try createContext(tempDir: buildContextDir, dockerfile: "", context: buildContext)

            let outputDir = dockerfileCtxDir.appendingPathComponent("diffpaths-local-output")
            let imageName = "local-diffpaths-test:\(UUID().uuidString)"

            let response = try buildWithPathsAndLocalOutput(
                tag: imageName,
                tempContext: buildContextDir,
                tempDockerfileContext: dockerfileCtxDir,
                outputDir: outputDir
            )

            // Verify the build succeeded
            #expect(response.contains("Successfully exported to"), "Expected successful local export message")

            // Verify the output directory exists
            #expect(FileManager.default.fileExists(atPath: outputDir.path), "Expected local output directory to exist")

            // Test building to existing output directory
            let existingTempDir: URL = try createTempDir()
            let existingDockerfile: String =
                """
                FROM scratch

                ADD newfile.txt /newfile.txt
                """
            let existingContext: [FileSystemEntry] = [
                .file("newfile.txt", content: .data("New content from build\n".data(using: .utf8)!))
            ]
            try createContext(tempDir: existingTempDir, dockerfile: existingDockerfile, context: existingContext)

            let existingOutputDir = existingTempDir.appendingPathComponent("existing-output")

            // Create the output directory and add some existing files
            try FileManager.default.createDirectory(at: existingOutputDir, withIntermediateDirectories: true)
            let existingFile = existingOutputDir.appendingPathComponent("existing.txt")
            try "Existing file content\n".data(using: .utf8)!.write(to: existingFile)

            let existingImageName = "local-existing-test:\(UUID().uuidString)"

            let existingResponse = try buildWithLocalOutput(tag: existingImageName, tempDir: existingTempDir, outputDir: existingOutputDir)

            // Verify the build succeeded
            #expect(existingResponse.contains("Successfully exported to"), "Expected successful local export message")

            // Verify the output directory exists
            #expect(FileManager.default.fileExists(atPath: existingOutputDir.path), "Expected local output directory to exist")

            // Verify the existing file is still there (local output should merge/overwrite)
            let contents = try FileManager.default.contentsOfDirectory(atPath: existingOutputDir.path)
            #expect(!contents.isEmpty, "Expected local output directory to contain files")

            // The behavior may vary - local output might overwrite the directory or merge contents
            // This test verifies that the operation completes successfully with an existing directory
        }

        @Test func testBuildLocalOutputFailure() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch

                ADD test.txt /test.txt
                """
            let context: [FileSystemEntry] = [
                .file("test.txt", content: .data("test\n".data(using: .utf8)!))
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            // Use a path that doesn't exist and can't be created (invalid parent)
            let invalidOutputDir = URL(fileURLWithPath: "/nonexistent/invalid/path")
            let imageName = "local-invalid-test:\(UUID().uuidString)"

            #expect(throws: CLIError.self) {
                try buildWithLocalOutput(tag: imageName, tempDir: tempDir, outputDir: invalidOutputDir)
            }
        }

        // Helper function to build with local output
        @discardableResult
        func buildWithLocalOutput(tag: String, tempDir: URL, outputDir: URL, args: [String]? = nil) throws -> String {
            try buildWithPathsAndLocalOutput(
                tag: tag,
                tempContext: tempDir,
                tempDockerfileContext: tempDir,
                outputDir: outputDir,
                args: args
            )
        }

        // Helper function to build with different paths and local output
        @discardableResult
        func buildWithPathsAndLocalOutput(
            tag: String,
            tempContext: URL,
            tempDockerfileContext: URL,
            outputDir: URL,
            args: [String]? = nil
        ) throws -> String {
            let contextDir: URL = tempContext.appendingPathComponent("context")
            let contextDirPath = contextDir.absoluteURL.path
            var buildArgs = [
                "build",
                "-f",
                tempDockerfileContext.appendingPathComponent("Dockerfile").path,
                "-t",
                tag,
                "--output",
                "type=local,dest=\(outputDir.path)",
            ]
            if let args = args {
                for arg in args {
                    buildArgs.append("--build-arg")
                    buildArgs.append(arg)
                }
            }
            buildArgs.append(contextDirPath)

            let response = try run(arguments: buildArgs)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            return response.output
        }
    }
}
