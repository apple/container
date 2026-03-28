//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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

import ComposeCore
import Foundation
import Logging
import Testing

@testable import ComposePlugin

@Suite(.serialized)
struct ComposeCommandTests {
    @Test
    func testDefaultProjectNameNormalizesDirectoryName() throws {
        let options = try makeOptions()
        let directory = URL(fileURLWithPath: "/tmp/My Compose App")
        #expect(options.defaultProjectName(for: directory) == "mycomposeapp")
    }

    @Test
    func testDefaultProjectNameSanitizesDirectoryBasenameForRuntimeIDs() throws {
        let options = try makeOptions()
        let directory = URL(fileURLWithPath: "/tmp/.devcontainer")
        #expect(options.defaultProjectName(for: directory) == "devcontainer")
    }

    @Test
    func testResolveProjectNamePrefersExplicitOverride() throws {
        var options = try makeOptions()
        options.project = "manual-name"

        let composeFile = ComposeFile(name: "from-compose")
        let resolved = options.resolveProjectName(
            composeFile: composeFile,
            fileURLs: [URL(fileURLWithPath: "/tmp/demo/compose.yaml")]
        )

        #expect(resolved == "manual-name")
    }

    @Test
    func testResolveProjectNameFallsBackToComposeNameThenDirectory() throws {
        let options = try makeOptions()
        let composeNamed = ComposeFile(name: "from-compose")
        let anonymousCompose = ComposeFile()
        let fileURL = URL(fileURLWithPath: "/tmp/Demo Stack/compose.yaml")

        #expect(options.resolveProjectName(composeFile: composeNamed, fileURLs: [fileURL]) == "from-compose")
        #expect(options.resolveProjectName(composeFile: anonymousCompose, fileURLs: [fileURL]) == "demo stack".replacingOccurrences(of: " ", with: ""))
    }

    @Test
    func testResolveProjectNameSanitizesComposeAndExplicitNamesForRuntimeIDs() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/Demo Stack/compose.yaml")
        let composeFile = ComposeFile(name: "My App")

        let options = try makeOptions()
        #expect(options.resolveProjectName(composeFile: composeFile, fileURLs: [fileURL]) == "myapp")

        var explicit = try makeOptions()
        explicit.project = "__My App__"
        #expect(explicit.resolveProjectName(composeFile: ComposeFile(), fileURLs: [fileURL]) == "myapp")
    }

    @Test
    func testGetProjectDirectoryUsesFirstComposeFile() throws {
        let options = try makeOptions()
        let directory = options.getProjectDirectory(fileURLs: [
            URL(fileURLWithPath: "/tmp/project/compose.yaml"),
            URL(fileURLWithPath: "/tmp/other/override.yaml"),
        ])

        #expect(directory.path == "/tmp/project")
    }

    @Test
    func testGetComposeFileURLsUsesExplicitRelativeAndAbsolutePaths() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let relative = tempDir.appendingPathComponent("relative.yml")
        let absolute = tempDir.appendingPathComponent("absolute.yml")
        try "".write(to: relative, atomically: true, encoding: .utf8)
        try "".write(to: absolute, atomically: true, encoding: .utf8)

        try withCurrentDirectory(tempDir) {
            var options = try makeOptions()
            options.file = ["relative.yml", absolute.path]
            let urls = options.getComposeFileURLs()

            #expect(urls.map(normalizedPath) == [relative, absolute].map(normalizedPath))
        }
    }

    @Test
    func testGetComposeFileURLsPrefersContainerComposeAndOverride() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let containerCompose = tempDir.appendingPathComponent("container-compose.yaml")
        let containerOverride = tempDir.appendingPathComponent("container-compose.override.yml")
        let plainCompose = tempDir.appendingPathComponent("compose.yaml")
        try "".write(to: containerCompose, atomically: true, encoding: .utf8)
        try "".write(to: containerOverride, atomically: true, encoding: .utf8)
        try "".write(to: plainCompose, atomically: true, encoding: .utf8)

        try withCurrentDirectory(tempDir) {
            let urls = try makeOptions().getComposeFileURLs()
            #expect(urls.map(\.lastPathComponent) == ["container-compose.yaml", "container-compose.override.yml"])
        }
    }

    @Test
    func testGetComposeFileURLsFallsBackToDockerComposeWhenNoFilesExist() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try withCurrentDirectory(tempDir) {
            let urls = try makeOptions().getComposeFileURLs()
            #expect(urls.count == 1)
            #expect(urls[0].lastPathComponent == "docker-compose.yml")
            #expect(urls[0].deletingLastPathComponent().lastPathComponent == tempDir.lastPathComponent)
        }
    }

    @Test
    func testSetEnvironmentVariablesExportsValues() throws {
        try withEnvironment("COMPOSE_PLUGIN_TEST_ENV", value: nil) {
            var options = try makeOptions()
            options.env = ["COMPOSE_PLUGIN_TEST_ENV=from-cli", "INVALID"]
            options.setEnvironmentVariables()
            let value = ProcessInfo.processInfo.environment["COMPOSE_PLUGIN_TEST_ENV"]
            #expect(value == "from-cli")
        }
    }

    @Test
    func testLoadDotEnvIfPresentHonorsProvidedDirectoryWithoutOverridingExistingEnv() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "COMPOSE_PLUGIN_DOTENV=file-value\n".write(
            to: tempDir.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        try withEnvironment("COMPOSE_PLUGIN_DOTENV", value: "existing") {
            let options = try makeOptions()
            options.loadDotEnvIfPresent(from: tempDir)
            let value = ProcessInfo.processInfo.environment["COMPOSE_PLUGIN_DOTENV"]
            #expect(value == "existing")
        }
    }

    @Test
    func testPrepareEnvironmentExportsDotEnvForEnvFileExpansion() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let composeURL = tempDir.appendingPathComponent("compose.yaml")
        let envFileURL = tempDir.appendingPathComponent("service.env")
        let dotEnvURL = tempDir.appendingPathComponent(".env")

        try """
        services:
          app:
            image: nginx:alpine
            env_file:
              - service.env
        """.write(to: composeURL, atomically: true, encoding: .utf8)
        try "DATABASE_URL=postgres://${DB_USER}@db\n".write(to: envFileURL, atomically: true, encoding: .utf8)
        try "DB_USER=alice\n".write(to: dotEnvURL, atomically: true, encoding: .utf8)

        try withEnvironment("DB_USER", value: nil) {
            let options = try makeOptions()
            let fileURLs = [composeURL]
            options.prepareEnvironment(fileURLs: fileURLs)

            let parser = ComposeParser(log: Logger(label: "test"))
            let composeFile = try parser.parse(from: fileURLs)
            options.exportDotEnvForEnvFileExpansion(fileURLs: fileURLs)
            let converter = ProjectConverter(log: Logger(label: "test"), projectDirectory: tempDir)
            let project = try converter.convert(composeFile: composeFile, projectName: "demo")
            let service = try #require(project.services["app"])

            #expect(ProcessInfo.processInfo.environment["DB_USER"] == "alice")
            #expect(service.environment["DATABASE_URL"] == "postgres://alice@db")
        }
    }

    @Test
    func testPrepareEnvironmentDoesNotLetRootDotEnvOverrideIncludeDefaultsDuringParse() throws {
        let rootDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let includeDir = rootDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)

        let rootCompose = rootDir.appendingPathComponent("compose.yaml")
        let includeCompose = includeDir.appendingPathComponent("compose.yaml")
        let rootDotEnv = rootDir.appendingPathComponent(".env")
        let includeDotEnv = includeDir.appendingPathComponent(".env")

        try """
        include:
          - ./vendor/compose.yaml
        services: {}
        """.write(to: rootCompose, atomically: true, encoding: .utf8)
        try """
        services:
          app:
            image: ${IMAGE_NAME}
        """.write(to: includeCompose, atomically: true, encoding: .utf8)
        try "IMAGE_NAME=root-value\n".write(to: rootDotEnv, atomically: true, encoding: .utf8)
        try "IMAGE_NAME=include-value\n".write(to: includeDotEnv, atomically: true, encoding: .utf8)

        try withEnvironment("IMAGE_NAME", value: nil) {
            let options = try makeOptions()
            let fileURLs = [rootCompose]
            options.prepareEnvironment(fileURLs: fileURLs)

            let parser = ComposeParser(log: Logger(label: "test"))
            let composeFile = try parser.parse(from: fileURLs)
            let app = try #require(composeFile.services["app"])

            #expect(ProcessInfo.processInfo.environment["IMAGE_NAME"] == nil)
            #expect(app.image == "include-value")
        }
    }

    private func makeOptions(arguments: [String] = []) throws -> ComposeOptions {
        try ComposeOptions.parse(arguments)
    }

    private func makeTempDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func withCurrentDirectory(_ directory: URL, body: () throws -> Void) throws {
        let original = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        #expect(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(original.path) }
        try body()
    }

    private func withEnvironment(_ key: String, value: String?, body: () throws -> Void) throws {
        let original = getenv(key).flatMap { String(cString: $0) }
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }

        defer {
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }

        try body()
    }

    private func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
