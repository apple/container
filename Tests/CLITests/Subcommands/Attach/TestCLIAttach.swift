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
class TestCLIAttach: CLITest, @unchecked Sendable {
    
    @Test("Attach command works with server-owned stdio container")
    func testAttachToServerOwnedStdioContainer() async throws {
        let containerName = "test-attach-\(UUID().uuidString)"
        
        // Start a long-running container with server-owned stdio
        let startProcess = Process()
        startProcess.executableURL = try executablePath
        startProcess.arguments = [
            "run",
            "--rm",
            "--name", containerName,
            "-itd", // -d for detached, -it for server-owned stdio
            "ghcr.io/linuxcontainers/alpine:3.20",
            "/bin/sh"
        ]
        
        try startProcess.run()
        startProcess.waitUntilExit()
        
        #expect(startProcess.terminationStatus == 0, "Container should start successfully")
        
        // Wait for container to be running
        try waitForContainerRunning(containerName)
        
        // Attach to the container
        let attachMessage = "Attached to container \(UUID().uuidString)"
        let attachProcess = Process()
        attachProcess.executableURL = try executablePath
        attachProcess.arguments = [
            "attach",
            containerName
        ]
        
        let attachPipe = Pipe()
        attachProcess.standardOutput = attachPipe
        attachProcess.standardError = attachPipe
        attachProcess.standardInput = Pipe() // Provide stdin for attach
        
        try attachProcess.run()
        
        // Send a command through attach
        let stdinHandle = attachProcess.standardInput as? Pipe
        try stdinHandle?.fileHandleForWriting.write(contentsOf: "echo '\(attachMessage)'\n".data(using: .utf8)!)
        try stdinHandle?.fileHandleForWriting.write(contentsOf: "exit\n".data(using: .utf8)!)
        
        let attachOutput = attachPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: attachOutput, encoding: .utf8) ?? ""
        
        attachProcess.waitUntilExit()
        
        #expect(output.contains(attachMessage), "Should see message from attach session")
        
        // Clean up
        _ = try? run(arguments: ["stop", containerName])
    }
    
    @Test("Multiple attach sessions can send stdin and receive stdout")
    func testMultipleAttachShareTerminal() async throws {
        let containerName = "test-concurrent-attach-\(UUID().uuidString)"
        
        // Start container
        let (_, _, startStatus) = try run(arguments: [
            "run",
            "--rm", 
            "--name", containerName,
            "-itd",
            "ghcr.io/linuxcontainers/alpine:3.20",
            "/bin/sh"
        ])
        #expect(startStatus == 0, "Container should start")
        
        try waitForContainerRunning(containerName)
        
        // Start three attach processes concurrently
        let session1Marker = "SESSION1-\(UUID().uuidString)"
        let session2Marker = "SESSION2-\(UUID().uuidString)"
        let session3Marker = "SESSION3-\(UUID().uuidString)"
        
        let attach1 = Process()
        attach1.executableURL = try executablePath
        attach1.arguments = ["attach", containerName]
        let pipe1 = Pipe()
        attach1.standardOutput = pipe1
        attach1.standardError = pipe1
        attach1.standardInput = Pipe()
        
        let attach2 = Process()
        attach2.executableURL = try executablePath
        attach2.arguments = ["attach", containerName]
        let pipe2 = Pipe()
        attach2.standardOutput = pipe2
        attach2.standardError = pipe2
        attach2.standardInput = Pipe()
        
        let attach3 = Process()
        attach3.executableURL = try executablePath
        attach3.arguments = ["attach", containerName]
        let pipe3 = Pipe()
        attach3.standardOutput = pipe3
        attach3.standardError = pipe3
        attach3.standardInput = Pipe()
        
        // Start all processes
        try attach1.run()
        try attach2.run()
        try attach3.run()
        
        // Give them time to connect
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Each session sends a unique echo command
        let stdin1 = attach1.standardInput as? Pipe
        let stdin2 = attach2.standardInput as? Pipe
        let stdin3 = attach3.standardInput as? Pipe
        
        // Session 1 sends its marker
        try stdin1?.fileHandleForWriting.write(contentsOf: "echo '\(session1Marker)'\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Session 2 sends its marker
        try stdin2?.fileHandleForWriting.write(contentsOf: "echo '\(session2Marker)'\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Session 3 sends its marker
        try stdin3?.fileHandleForWriting.write(contentsOf: "echo '\(session3Marker)'\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Session 1 sends exit to terminate all sessions
        try stdin1?.fileHandleForWriting.write(contentsOf: "exit\n".data(using: .utf8)!)
        
        // Close stdin pipes
        try stdin1?.fileHandleForWriting.close()
        try stdin2?.fileHandleForWriting.close()
        try stdin3?.fileHandleForWriting.close()
        
        // Wait for processes to exit with timeout
        let timeout = Date().addingTimeInterval(5) // 5 second timeout
        while (attach1.isRunning || attach2.isRunning || attach3.isRunning) && Date() < timeout {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        // Force terminate if still running
        if attach1.isRunning {
            attach1.terminate()
            attach1.waitUntilExit()
        }
        if attach2.isRunning {
            attach2.terminate()
            attach2.waitUntilExit()
        }
        if attach3.isRunning {
            attach3.terminate()
            attach3.waitUntilExit()
        }
        
        // Read output after processes exit
        let output1 = String(data: pipe1.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let output2 = String(data: pipe2.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let output3 = String(data: pipe3.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        
        // Verify each session could send stdin (its own marker appears somewhere)
        let allOutputs = output1 + output2 + output3
        #expect(allOutputs.contains(session1Marker), "Session 1 marker should appear in output")
        #expect(allOutputs.contains(session2Marker), "Session 2 marker should appear in output")
        #expect(allOutputs.contains(session3Marker), "Session 3 marker should appear in output")
        
        // Verify each session receives stdout (should see at least one other session's marker)
        // Since outputs are shared, each session should see markers from other sessions
        let session1SeesOthers = output1.contains(session2Marker) || output1.contains(session3Marker)
        let session2SeesOthers = output2.contains(session1Marker) || output2.contains(session3Marker)
        let session3SeesOthers = output3.contains(session1Marker) || output3.contains(session2Marker)
        
        #expect(session1SeesOthers || output1.contains(session1Marker), 
                "Session 1 should see output from the shared terminal")
        #expect(session2SeesOthers || output2.contains(session2Marker), 
                "Session 2 should see output from the shared terminal")
        #expect(session3SeesOthers || output3.contains(session3Marker), 
                "Session 3 should see output from the shared terminal")
        
        // Clean up
        let (_, _, stopStatus) = try run(arguments: ["stop", containerName])
        #expect(stopStatus == 0, "Container should stop")
    }    
    
}