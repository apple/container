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

import Foundation
import Testing
import Logging
@testable import ComposeCore

// Local minimal replica to avoid importing the CLI @main target in tests
private struct TestComposeOptions {
    func getComposeFileURLs() -> [URL] {
        let currentPath = FileManager.default.currentDirectoryPath
        let candidates = [
            "docker-compose.yml",
            "docker-compose.yaml",
            "compose.yml",
            "compose.yaml",
        ]
        for base in candidates {
            let baseURL = URL(fileURLWithPath: currentPath).appendingPathComponent(base)
            if FileManager.default.fileExists(atPath: baseURL.path) {
                var urls = [baseURL]
                let overrideCandidates: [String] = base.hasPrefix("docker-compose") ? [
                    "docker-compose.override.yml", "docker-compose.override.yaml"
                ] : [
                    "compose.override.yml", "compose.override.yaml"
                ]
                for o in overrideCandidates {
                    let oURL = URL(fileURLWithPath: currentPath).appendingPathComponent(o)
                    if FileManager.default.fileExists(atPath: oURL.path) { urls.append(oURL) }
                }
                return urls
            }
        }
        return [URL(fileURLWithPath: currentPath).appendingPathComponent("docker-compose.yml")]
    }

    func loadDotEnvIfPresent() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        _ = EnvLoader.load(from: cwd, export: true, override: false)
    }
}

struct ComposeOptionsTests {
    @Test
    func testDefaultFileStackingDockerCompose() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Create base and override
        let base = tempDir.appendingPathComponent("docker-compose.yml")
        let override = tempDir.appendingPathComponent("docker-compose.override.yml")
        try "version: '3'\nservices: {}\n".write(to: base, atomically: true, encoding: .utf8)
        try "services: {}\n".write(to: override, atomically: true, encoding: .utf8)

        // Swap to temp dir
        let cwd = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(cwd) }
        _ = fm.changeCurrentDirectoryPath(tempDir.path)

        let opts = TestComposeOptions()
        let urls = opts.getComposeFileURLs()
        #expect(urls.count == 2)
        #expect(urls[0].lastPathComponent == "docker-compose.yml")
        #expect(urls[1].lastPathComponent == "docker-compose.override.yml")
    }

    @Test
    func testDefaultFileStackingComposeYaml() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Create base and override
        let base = tempDir.appendingPathComponent("compose.yaml")
        let override = tempDir.appendingPathComponent("compose.override.yaml")
        try "services: {}\n".write(to: base, atomically: true, encoding: .utf8)
        try "services: {}\n".write(to: override, atomically: true, encoding: .utf8)

        // Swap to temp dir
        let cwd = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(cwd) }
        _ = fm.changeCurrentDirectoryPath(tempDir.path)

        let opts = TestComposeOptions()
        let urls = opts.getComposeFileURLs()
        #expect(urls.count == 2)
        #expect(urls[0].lastPathComponent == "compose.yaml")
        #expect(urls[1].lastPathComponent == "compose.override.yaml")
    }

    @Test
    func testDotEnvInterpolation() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Write .env
        try "FOO=bar\n".write(to: tempDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        // Compose referencing ${FOO}
        let yaml = """
        version: '3'
        services:
          app:
            image: ${FOO:-busybox}
        """
        let composeURL = tempDir.appendingPathComponent("docker-compose.yml")
        try yaml.write(to: composeURL, atomically: true, encoding: .utf8)

        // Change cwd and load .env
        let cwd = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(cwd) }
        _ = fm.changeCurrentDirectoryPath(tempDir.path)

        let opts = TestComposeOptions()
        opts.loadDotEnvIfPresent()

        let parser = ComposeParser(log: Logger(label: "test"))
        let cf = try parser.parse(from: composeURL)
        #expect(cf.services["app"]?.image == "bar")
    }
}
