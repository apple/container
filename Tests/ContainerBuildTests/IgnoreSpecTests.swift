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

@testable import ContainerBuild

enum TestError: Error {
    case missingBuildTransfer
}

@Suite class IgnoreSpecTests {
    private var baseTempURL: URL
    private let fileManager = FileManager.default

    init() throws {
        self.baseTempURL = URL.temporaryDirectory
            .appendingPathComponent("IgnoreSpecTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: baseTempURL, withIntermediateDirectories: true, attributes: nil)
    }

    deinit {
        try? fileManager.removeItem(at: baseTempURL)
    }

    private func createFile(at url: URL, content: String = "") throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let created = fileManager.createFile(
            atPath: url.path,
            contents: content.data(using: .utf8),
            attributes: nil
        )
        try #require(created)
    }

    // MARK: - Unit tests for IgnoreSpec

    @Test func testIgnoreSpecParsesPatterns() throws {
        let content = """
            # This is a comment
            *.log

            node_modules
            # Another comment
            temp/
            """
        let data = content.data(using: .utf8)!
        let spec = IgnoreSpec(data)

        // Test that it correctly ignores files matching patterns
        #expect(try spec.shouldIgnore(relPath: "debug.log", isDirectory: false))
        #expect(try spec.shouldIgnore(relPath: "node_modules", isDirectory: true))
        #expect(try spec.shouldIgnore(relPath: "temp/", isDirectory: true))
        #expect(try !spec.shouldIgnore(relPath: "src/app.swift", isDirectory: false))
    }

    @Test func testIgnoreSpecHandlesEmptyData() throws {
        let data = Data()
        let spec = IgnoreSpec(data)

        // Empty spec should not ignore anything
        #expect(try !spec.shouldIgnore(relPath: "anyfile.txt", isDirectory: false))
    }

    @Test func testIgnoreSpecHandlesNestedPaths() throws {
        let content = "*.log"
        let data = content.data(using: .utf8)!
        let spec = IgnoreSpec(data)

        // Should match .log files in nested directories
        #expect(try spec.shouldIgnore(relPath: "logs/debug.log", isDirectory: false))
        #expect(try spec.shouldIgnore(relPath: "app/logs/error.log", isDirectory: false))
        #expect(try !spec.shouldIgnore(relPath: "logs/debug.txt", isDirectory: false))
    }

    @Test func testIgnoreSpecHandlesDirectories() throws {
        let content = "node_modules"
        let data = content.data(using: .utf8)!
        let spec = IgnoreSpec(data)

        // Should match directories
        #expect(try spec.shouldIgnore(relPath: "node_modules", isDirectory: true))
        #expect(try spec.shouldIgnore(relPath: "src/node_modules", isDirectory: true))
    }

    // MARK: - Integration tests with BuildFSSync

    @Test func testDockerignoreExcludesMatchingFiles() async throws {
        // Setup: Create a build context with files and .dockerignore
        let contextDir = baseTempURL.appendingPathComponent("build-context")
        try fileManager.createDirectory(at: contextDir, withIntermediateDirectories: true, attributes: nil)

        // Create Dockerfile
        let dockerfilePath = contextDir.appendingPathComponent("Dockerfile")
        try createFile(at: dockerfilePath, content: "FROM scratch\n")

        // Create hello.txt (should be included)
        let helloPath = contextDir.appendingPathComponent("hello.txt")
        try createFile(at: helloPath, content: "Hello, World!\n")

        // Create to-be-ignored.txt (should be excluded)
        let ignoredPath = contextDir.appendingPathComponent("to-be-ignored.txt")
        try createFile(at: ignoredPath, content: "This should be ignored\n")

        // Create .dockerignore
        let dockerignorePath = contextDir.appendingPathComponent(".dockerignore")
        try createFile(at: dockerignorePath, content: "to-be-ignored.txt\n")

        // Execute: Create BuildFSSync and call walk with all files pattern
        let fsSync = try BuildFSSync(contextDir)

        // Create a BuildTransfer packet to simulate the walk request
        let buildTransfer: BuildTransfer = {
            var transfer = BuildTransfer()
            transfer.id = "test-walk"
            transfer.source = "."
            transfer.metadata = [
                "stage": "fssync",
                "method": "Walk",
                "followpaths": "**",  // Include all files
                "mode": "json",
            ]
            return transfer
        }()

        // Capture the response
        var responses: [ClientStream] = []
        let stream = AsyncStream<ClientStream> { continuation in
            Task {
                do {
                    try await fsSync.walk(continuation, buildTransfer, "test-build")
                } catch {
                    // Propagate error
                    throw error
                }
                continuation.finish()
            }
        }

        for await response in stream {
            responses.append(response)
        }

        // Parse the JSON response
        try #require(responses.count == 1, "Expected exactly one response")
        let response = responses[0]

        // Check if the response has a buildTransfer packet type
        guard case .buildTransfer(let responseTransfer) = response.packetType else {
            throw TestError.missingBuildTransfer
        }

        try #require(responseTransfer.complete, "Response should be complete")

        let fileInfos = try JSONDecoder().decode([BuildFSSync.FileInfo].self, from: responseTransfer.data)

        // Extract file names
        let fileNames = Set(fileInfos.map { $0.name })

        // Assert: Verify hello.txt is present and to-be-ignored.txt is NOT present
        #expect(fileNames.contains("hello.txt"), "hello.txt should be included in the build context")
        #expect(!fileNames.contains("to-be-ignored.txt"), "to-be-ignored.txt should be excluded by .dockerignore")
        #expect(fileNames.contains("Dockerfile"), "Dockerfile should be included")

        // The .dockerignore file itself should also be included (Docker behavior)
        #expect(fileNames.contains(".dockerignore"), ".dockerignore should be included")
    }

    @Test func testDockerignoreExcludesDirectories() async throws {
        // Setup: Create a build context with directories and .dockerignore
        let contextDir = baseTempURL.appendingPathComponent("build-context-dirs")
        try fileManager.createDirectory(at: contextDir, withIntermediateDirectories: true, attributes: nil)

        // Create Dockerfile
        let dockerfilePath = contextDir.appendingPathComponent("Dockerfile")
        try createFile(at: dockerfilePath, content: "FROM scratch\n")

        // Create src/app.txt (should be included)
        let srcPath = contextDir.appendingPathComponent("src")
        try fileManager.createDirectory(at: srcPath, withIntermediateDirectories: true, attributes: nil)
        let appPath = srcPath.appendingPathComponent("app.txt")
        try createFile(at: appPath, content: "app code\n")

        // Create node_modules/package.txt (should be excluded)
        let nodeModulesPath = contextDir.appendingPathComponent("node_modules")
        try fileManager.createDirectory(at: nodeModulesPath, withIntermediateDirectories: true, attributes: nil)
        let packagePath = nodeModulesPath.appendingPathComponent("package.txt")
        try createFile(at: packagePath, content: "dependency\n")

        // Create .dockerignore
        let dockerignorePath = contextDir.appendingPathComponent(".dockerignore")
        try createFile(at: dockerignorePath, content: "node_modules\n")

        // Execute: Create BuildFSSync and call walk
        let fsSync = try BuildFSSync(contextDir)

        let buildTransfer: BuildTransfer = {
            var transfer = BuildTransfer()
            transfer.id = "test-walk-dirs"
            transfer.source = "."
            transfer.metadata = [
                "stage": "fssync",
                "method": "Walk",
                "followpaths": "**",
                "mode": "json",
            ]
            return transfer
        }()

        var responses: [ClientStream] = []
        let stream = AsyncStream<ClientStream> { continuation in
            Task {
                do {
                    try await fsSync.walk(continuation, buildTransfer, "test-build")
                } catch {
                    throw error
                }
                continuation.finish()
            }
        }

        for await response in stream {
            responses.append(response)
        }

        // Parse the JSON response
        try #require(responses.count == 1)
        let response = responses[0]

        guard case .buildTransfer(let responseTransfer) = response.packetType else {
            throw TestError.missingBuildTransfer
        }

        let fileInfos = try JSONDecoder().decode([BuildFSSync.FileInfo].self, from: responseTransfer.data)
        let fileNames = Set(fileInfos.map { $0.name })

        // Assert: Verify src is included, node_modules is excluded
        #expect(fileNames.contains("src"), "src directory should be included")
        #expect(fileNames.contains("src/app.txt"), "src/app.txt should be included")
        #expect(!fileNames.contains("node_modules"), "node_modules directory should be excluded")
        #expect(!fileNames.contains("node_modules/package.txt"), "node_modules/package.txt should be excluded")
    }
}
