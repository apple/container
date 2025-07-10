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

import Testing
import Foundation
import ContainerizationOS
@testable import container

/// Integration tests for server-owned stdio using the actual container CLI binary
/// These tests follow the existing integration test patterns in the codebase
class TestCLIRunLegacyIO: CLITest, @unchecked Sendable {
    
    @Test("Legacy stdio flag forces client-owned stdio")
    func testLegacyStdioFlag() async throws {
        let containerName = "test-legacy-stdio-\(UUID().uuidString)"
        let testMessage = "Legacy stdio test \(UUID().uuidString)"
        
        // Use runInteractive with explicit --legacy-stdio flag
        let terminal = try runInteractive(arguments: [
            "run",
            "--legacy-stdio",
            "--rm",
            "--name", containerName,
            "-it",
            "ghcr.io/linuxcontainers/alpine:3.20",
            "/bin/sh"
        ])
        
        // With legacy stdio, we can interact via the terminal
        let stdoutTask = Task {
            for try await line in terminal.readLines() {
                if line.contains(testMessage) {
                    return true
                }
            }
            return false
        }
        
        // Send commands
        try terminal.write("echo '\(testMessage)'\n")
        try terminal.write("exit\n")
        
        let found = try await stdoutTask.value
        #expect(found, "Should see test message with legacy stdio")
    }
    
    @Test("Environment variable forces legacy stdio")
    func testEnvironmentVariableLegacyStdio() async throws {
        let containerName = "test-env-legacy-\(UUID().uuidString)"
        let testMessage = "Env legacy stdio \(UUID().uuidString)"
        
        // Set environment variable
        let process = Process()
        process.executableURL = try executablePath
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["CONTAINER_LEGACY_STDIO"] = "1"
        
        process.arguments = [
            "run",
            "--rm",
            "--name", containerName,
            "-it", // Would normally trigger server stdio
            "ghcr.io/linuxcontainers/alpine:3.20",
            "/bin/sh", "-c", "echo '\(testMessage)'"
        ]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        
        // With legacy stdio forced by env var, we need to provide stdin
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        
        try process.run()
        
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputStr = String(data: output, encoding: .utf8) ?? ""
        
        process.waitUntilExit()
        
        #expect(outputStr.contains(testMessage), "Should see output with env-forced legacy stdio")
        #expect(process.terminationStatus == 0, "Should exit successfully")
    }
}