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

struct EnvFileTests {
    let log = Logger(label: "test")

    @Test
    func testEnvFileMergesIntoEnvironment() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let envPath = tempDir.appendingPathComponent(".myenv")
        try "A=1\nB=2\n# comment\nexport C=3\nQUOTED='x y'\n".write(to: envPath, atomically: true, encoding: .utf8)

        let yaml = """
        version: '3'
        services:
          app:
            image: alpine
            env_file:
              - ./.myenv
            environment:
              B: override
              D: 4
        """

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        let converter = ProjectConverter(log: log)

        // Change cwd to temp to resolve relative env_file
        let cwd = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(cwd) }
        _ = fm.changeCurrentDirectoryPath(tempDir.path)

        let project = try converter.convert(composeFile: composeFile, projectName: "test")
        let env = try #require(project.services["app"]) .environment
        #expect(env["A"] == "1")
        #expect(env["B"] == "override") // environment overrides env_file
        #expect(env["C"] == "3")
        #expect(env["D"] == "4")
        #expect(env["QUOTED"] == "x y")
    }

    @Test
    func testEnvFileSecurityValidation() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let envPath = tempDir.appendingPathComponent(".env")
        try "SECRET_KEY=secret123\nAPI_KEY=apikey456".write(to: envPath, atomically: true, encoding: .utf8)

        // Make the file world-readable (insecure)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: envPath.path)

        // Use an actor to safely capture log messages
        let logCapture = LogCapture()
        let testLogger = Logger(label: "test") { label in
            TestLogHandler { message in
                Task { await logCapture.append(message) }
            }
        }

        // Load the .env file
        let result = EnvLoader.load(from: tempDir, export: false, logger: testLogger)

        // Verify the values were loaded
        #expect(result["SECRET_KEY"] == "secret123")
        #expect(result["API_KEY"] == "apikey456")

        // Verify security warning was logged (allow a brief tick for capture)
        try await Task.sleep(nanoseconds: 100_000_000)
        let messages = await logCapture.getMessages()
        #expect(messages.contains { $0.contains("is readable by group/other") })
    }

    @Test
    func testEnvFileSecurePermissions() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let envPath = tempDir.appendingPathComponent(".env")
        try "SECURE_VAR=secure_value".write(to: envPath, atomically: true, encoding: .utf8)

        // Make the file secure (owner read/write only)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envPath.path)

        // Use an actor to safely capture log messages
        let logCapture = LogCapture()
        let testLogger = Logger(label: "test") { label in
            TestLogHandler { message in
                Task { await logCapture.append(message) }
            }
        }

        // Load the .env file
        let result = EnvLoader.load(from: tempDir, export: false, logger: testLogger)

        // Verify the value was loaded
        #expect(result["SECURE_VAR"] == "secure_value")

        // Verify no security warning was logged
        let messages = await logCapture.getMessages()
        #expect(!messages.contains { $0.contains("is readable by group/other") })
    }
}

// Actor to safely capture log messages
actor LogCapture {
    private var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }

    func getMessages() -> [String] {
        return messages
    }
}

// Helper for testing log messages
final class TestLogHandler: LogHandler {
    let label: String = "test"
    var logLevel: Logger.Level = .info
    let capture: @Sendable (String) -> Void

    init(_ capture: @escaping @Sendable (String) -> Void) {
        self.capture = capture
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        capture(message.description)
    }

    subscript(metadataKey _: String) -> Logger.Metadata.Value? {
        get { nil }
        set {}
    }

    var metadata: Logger.Metadata = [:]
}
