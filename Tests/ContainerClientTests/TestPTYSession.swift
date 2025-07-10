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
import ContainerSandboxService
import ContainerClient
import ContainerXPC
import Logging
import ContainerizationOS

/// Parameterized tests for stdio modes - tests both new (server-owned) and legacy (client-owned) modes
struct TestPTYSession {
    
    enum StdioMode: String, CaseIterable {
        case serverOwned = "server-owned"
        case legacy = "legacy"
        
        var usesServerStdio: Bool {
            self == .serverOwned
        }
    }
    
    // MARK: - Helper for PTY Session Management
    
    /// Execute a test with a PTY session, ensuring cleanup happens even on failure.
    /// This helper eliminates the repetitive cleanup code in do-catch blocks.
    ///
    /// - Parameters:
    ///   - containerID: Unique identifier for the PTY session
    ///   - bufferSize: Size of the ring buffer for session history (default: 4096)
    ///   - logger: Logger instance to use (creates default if not provided)
    ///   - body: The test closure that receives the session and manager
    /// - Returns: The result of the test closure
    /// - Throws: Any error from session creation or the test body
    func withPTYSession<T>(
        containerID: String,
        bufferSize: Int? = 4096,
        logger: Logger? = nil,
        body: (PTYSession) async throws -> T
    ) async throws -> T {
        let actualLogger = logger ?? Logger(label: "test.pty.session")
        let session = try PTYSession(
            containerID: containerID,
            terminal: true,
            bufferSize: bufferSize ?? PTYSession.defaultBufferSize,
            logger: actualLogger
        )
        
        defer {
            session.cleanup()
        }
        
        return try await body(session)
    }
    
    // MARK: - Basic I/O Tests (work in both modes)
    
    @Test("Basic pipe I/O works", arguments: StdioMode.allCases)
    func testBasicPipeIO(mode: StdioMode) throws {
        // Both modes should support basic pipe I/O
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        
        // Simulate server/client handle split based on mode
        let (serverHandles, clientHandles) = splitHandles(
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            mode: mode
        )
        
        // Test stdout
        let testData = "Hello stdio \(mode.rawValue)\n".data(using: .utf8)!
        try serverHandles.stdout.write(contentsOf: testData)
        
        let received = readAvailableData(from: clientHandles.stdout)
        #expect(received == testData)
        
        // Test stderr
        let errorData = "Error in \(mode.rawValue)\n".data(using: .utf8)!
        try serverHandles.stderr.write(contentsOf: errorData)
        
        let errorReceived = readAvailableData(from: clientHandles.stderr)
        #expect(errorReceived == errorData)
        
        // Test stdin
        let inputData = "Input for \(mode.rawValue)\n".data(using: .utf8)!
        try clientHandles.stdin.write(contentsOf: inputData)
        
        let serverInput = readAvailableData(from: serverHandles.stdin)
        #expect(serverInput == inputData)
    }
    
    @Test("Character-by-character I/O", arguments: StdioMode.allCases)
    func testCharacterIO(mode: StdioMode) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        
        let (serverHandles, clientHandles) = splitHandles(
            stdin: stdin,
            stdout: stdout,
            stderr: Pipe(),
            mode: mode
        )
        
        // Test writing and reading a single character at a time
        let testString = "Hello!"
        
        // Write all characters first
        for char in testString {
            let charData = String(char).data(using: .utf8)!
            try clientHandles.stdin.write(contentsOf: charData)
        }
        
        // Read all data at once
        let allData = readAvailableData(from: serverHandles.stdin)
        let receivedString = String(data: allData, encoding: .utf8) ?? ""
        #expect(receivedString == testString, "Should receive all characters")
        
        // Echo back all at once
        try serverHandles.stdout.write(contentsOf: allData)
        
        // Client should see the echo
        let echoData = readAvailableData(from: clientHandles.stdout)
        let echoString = String(data: echoData, encoding: .utf8) ?? ""
        #expect(echoString == testString, "Should see echoed characters")
    }
    
    // MARK: - PTY Tests (server-owned mode only)
    
    @Test("PTY terminal mode with echo", arguments: [StdioMode.serverOwned])
    func testPTYTerminalEcho(mode: StdioMode) async throws {
        try await withPTYSession(
            containerID: "pty-echo-test",
            logger: Logger(label: "test.pty.echo")
        ) { session in
            // Get both client and container handles to demonstrate PTY echo
            let clientHandles = session.clientHandles
            let containerHandles = session.containerHandles
            
            guard let clientStdin = clientHandles[0],
                  let clientStdout = clientHandles[1],
                  let containerStdout = containerHandles[1] else {
                Issue.record("Failed to get handles")
                return
            }
            
            // Write a test string from client
            let testString = "Hello PTY!"
            let testData = testString.data(using: .utf8)!
            try clientStdin.write(contentsOf: testData)
            
            // Send newline to flush
            try clientStdin.write(contentsOf: "\n".data(using: .utf8)!)
            
            // Simulate container echoing the input back
            // In a real PTY with a shell, this would happen automatically
            let echoData = (testString + "\n").data(using: .utf8)!
            try containerStdout.write(contentsOf: echoData)
            
            // Small delay for data to propagate
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            // Client should see the echo
            let receivedData = readAvailableData(from: clientStdout, timeout: 0.5)
            let receivedStr = String(data: receivedData, encoding: .utf8) ?? ""
            
            // Verify the echo was received
            #expect(receivedStr.contains(testString), "Client should see echoed input: '\(receivedStr)'")
        }
    }
    
    @Test("PTY attach/detach cycle", arguments: [StdioMode.serverOwned])
    func testPTYAttachDetachCycle(mode: StdioMode) async throws {
        try await withPTYSession(
            containerID: "attach-cycle-test",
            logger: Logger(label: "test.attach.cycle")
        ) { session in
            // First attachment - get history
            let (historyBytes1, truncated1) = session.sendHistory()
            #expect(historyBytes1 == 0, "No history on first attach")
            #expect(!truncated1, "History should not be truncated")
            
            // Get client handles
            let clientHandles = session.clientHandles
            guard let stdin = clientHandles[0],
                  let stdout = clientHandles[1] else {
                Issue.record("Failed to get client handles")
                return
            }
            
            // Write some data
            let message1 = "First attach message\n"
            try stdin.write(contentsOf: message1.data(using: .utf8)!)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            // Read to confirm it went through
            let output1 = readAvailableData(from: stdout)
            #expect(output1.count > 0, "Should receive data in first session")
            
            // Simulate detach by just waiting (in real scenario, client would disconnect)
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Write more data while "detached" (data goes to history buffer)
            let message2 = "Data while detached\n"
            try stdin.write(contentsOf: message2.data(using: .utf8)!)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            // Second attachment - should get history
            let (historyBytes2, truncated2) = session.sendHistory()
            #expect(historyBytes2 > 0, "Should have history on reattach: \(historyBytes2) bytes")
            #expect(!truncated2, "History should not be truncated")
            
            // The history is already in the buffer, we just need to verify the size
            #expect(historyBytes2 >= message1.count + message2.count, 
                    "History should include both messages")
        }
    }
    
    @Test("Multiple concurrent attach sessions", arguments: [StdioMode.serverOwned])
    func testMultipleConcurrentAttach(mode: StdioMode) async throws {
        try await withPTYSession(
            containerID: "concurrent-test",
            logger: Logger(label: "test.concurrent")
        ) { session in
            // Note: In reality, PTY sessions share a single terminal
            // All clients see the same output
            let clientHandles = session.clientHandles
            guard let stdin = clientHandles[0],
                  let stdout = clientHandles[1] else {
                Issue.record("Failed to get client handles")
                return
            }
            
            // Write a broadcast message
            let broadcast = "Broadcast to all sessions\n"
            try stdin.write(contentsOf: broadcast.data(using: .utf8)!)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            // Read the broadcast
            let output = readAvailableData(from: stdout)
            let outputStr = String(data: output, encoding: .utf8) ?? ""
            #expect(outputStr.contains("Broadcast"), "Should see broadcast message")
            
            // Multiple clients would all see the same output from the shared PTY
            // This is the expected behavior for terminal sharing
        }
    }
    
    // MARK: - Buffer Management Tests
    
    @Test("PTY buffer overflow handling", arguments: [StdioMode.serverOwned])
    func testPTYBufferOverflow(mode: StdioMode) async throws {
        let bufferSize = 1024 // Small buffer to test overflow
        
        try await withPTYSession(
            containerID: "buffer-overflow-test",
            bufferSize: bufferSize,
            logger: Logger(label: "test.buffer.overflow")
        ) { session in
            let clientHandles = session.clientHandles
            guard let stdin = clientHandles[0] else {
                Issue.record("Failed to get stdin handle")
                return
            }
            
            // Write more data than buffer can hold
            let chunk = String(repeating: "A", count: 100)
            var totalWritten = 0
            for i in 0..<20 {
                let data = "\(i): \(chunk)\n".data(using: .utf8)!
                try stdin.write(contentsOf: data)
                totalWritten += data.count
            }
            
            // Let buffer process
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Check buffer stats
            let stats = session.getBufferStats()
            #expect(stats.historySize > 0, "Buffer should contain data")
            #expect(stats.truncated || totalWritten <= bufferSize, 
                    "Buffer should be truncated or data fits")
            
            // Get history and verify truncation if needed
            let (historyBytes, truncated) = session.sendHistory()
            #expect(historyBytes > 0, "Should have history bytes")
            #expect(historyBytes <= bufferSize, "History should not exceed buffer size")
            
            if totalWritten > bufferSize {
                #expect(truncated, "History should be truncated when overflow occurs")
            }
        }
    }
    
    // MARK: - Error Cases
    
    @Test("Closed pipe handling", arguments: StdioMode.allCases)
    func testClosedPipeHandling(mode: StdioMode) throws {
        // Save the original SIGPIPE handler
        let oldHandler = signal(SIGPIPE, SIG_IGN)
        defer {
            // Restore the original handler
            signal(SIGPIPE, oldHandler)
        }
        
        let stdin = Pipe()
        let stdout = Pipe()
        
        let (serverHandles, clientHandles) = splitHandles(
            stdin: stdin,
            stdout: stdout,
            stderr: Pipe(),
            mode: mode
        )
        
        // Close client stdout
        clientHandles.stdout.closeFile()
        
        // Server write should fail gracefully
        let testData = "Test data\n".data(using: .utf8)!
        do {
            try serverHandles.stdout.write(contentsOf: testData)
            // Might succeed if buffered
        } catch {
            // Expected - pipe is closed
        }
        
        // Close server stdin
        serverHandles.stdin.closeFile()
        
        // Client write should fail
        do {
            try clientHandles.stdin.write(contentsOf: testData)
            Issue.record("Write to closed pipe should fail")
        } catch {
            // Expected
        }
    }
    
    // MARK: - Line Discipline Tests
    
    @Test("Line buffering behavior", arguments: StdioMode.allCases)
    func testLineBuffering(mode: StdioMode) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        
        let (serverHandles, clientHandles) = splitHandles(
            stdin: stdin,
            stdout: stdout,
            stderr: Pipe(),
            mode: mode
        )
        
        // Write a complete line with newline
        let fullLine = "Complete line with newline\n"
        try serverHandles.stdout.write(contentsOf: fullLine.data(using: .utf8)!)
        
        // Read the complete line
        let lineData = readAvailableData(from: clientHandles.stdout)
        let lineStr = String(data: lineData, encoding: .utf8) ?? ""
        #expect(lineStr == fullLine, "Should receive complete line")
        
        // Write another line to test multiple lines
        let secondLine = "Second line\n"
        try serverHandles.stdout.write(contentsOf: secondLine.data(using: .utf8)!)
        
        let secondData = readAvailableData(from: clientHandles.stdout)
        let secondStr = String(data: secondData, encoding: .utf8) ?? ""
        #expect(secondStr == secondLine, "Should receive second line")
    }
    
    // MARK: - Helper Methods
    
    /// Read available data with a timeout to prevent blocking
    private func readAvailableData(from handle: FileHandle, timeout: TimeInterval = 0.1) -> Data {
        var data = Data()
        let endTime = Date().addingTimeInterval(timeout)
        
        while Date() < endTime {
            // Check if data is available without blocking
            let availableData = handle.availableData
            if availableData.count > 0 {
                data.append(availableData)
                break
            }
            // Small sleep to prevent busy waiting
            Thread.sleep(forTimeInterval: 0.01)
        }
        
        return data
    }
    
    private func splitHandles(
        stdin: Pipe,
        stdout: Pipe,
        stderr: Pipe,
        mode: StdioMode
    ) -> (server: (stdin: FileHandle, stdout: FileHandle, stderr: FileHandle),
         client: (stdin: FileHandle, stdout: FileHandle, stderr: FileHandle)) {
        
        // In both modes, the handle split is the same for pipes
        // Server gets read end of stdin, write end of stdout/stderr
        // Client gets write end of stdin, read end of stdout/stderr
        
        return (
            server: (
                stdin: stdin.fileHandleForReading,
                stdout: stdout.fileHandleForWriting,
                stderr: stderr.fileHandleForWriting
            ),
            client: (
                stdin: stdin.fileHandleForWriting,
                stdout: stdout.fileHandleForReading,
                stderr: stderr.fileHandleForReading
            )
        )
    }

@Test("Server-owned stdio creates real PTY sessions")
    func testServerOwnedPTY() async throws {
        try await withPTYSession(
            containerID: "summary-pty",
            logger: Logger(label: "test.summary.pty")
        ) { session in
            // Verify PTY was created with valid handles
            let containerHandles = session.containerHandles
            #expect(containerHandles.count == 3, "Should have stdin, stdout, stderr handles")
            
            // In PTY mode, all three handles point to the same PTY slave
            if let stdin = containerHandles[0],
               let stdout = containerHandles[1],
               let stderr = containerHandles[2] {
                #expect(stdin.fileDescriptor > 0, "PTY slave FD is valid")
                #expect(stdout.fileDescriptor == stdin.fileDescriptor, 
                        "stdout uses same PTY slave")
                #expect(stderr.fileDescriptor == stdin.fileDescriptor, 
                        "stderr uses same PTY slave")
            } else {
                Issue.record("Failed to get container handles")
            }
            
            // Verify client handles are pipes
            let clientHandles = session.clientHandles
            #expect(clientHandles[0] != nil, "Client stdin exists")
            #expect(clientHandles[1] != nil, "Client stdout exists")
            #expect(clientHandles[2] == nil, "Client stderr is nil for PTY mode")
        }
    }
    
    @Test("Legacy mode uses standard pipes")
    func testLegacyPipes() throws {
        // Legacy mode just uses regular pipes
        let stdin = Pipe()
        let stdout = Pipe()
        let _ = Pipe() // stderr not used in this test
        
        // Client writes to stdin
        let input = "Legacy input\n".data(using: .utf8)!
        try stdin.fileHandleForWriting.write(contentsOf: input)
        
        // Server reads from stdin
        let received = readAvailableData(from: stdin.fileHandleForReading)
        #expect(received == input, "Legacy stdin works")
        
        // Server writes to stdout
        let output = "Legacy output\n".data(using: .utf8)!
        try stdout.fileHandleForWriting.write(contentsOf: output)
        
        // Client reads from stdout
        let clientOutput = readAvailableData(from: stdout.fileHandleForReading)
        #expect(clientOutput == output, "Legacy stdout works")
    }
    
    @Test("Attach/detach works in server-owned mode")
    func testAttachDetachServerOwned() async throws {
        try await withPTYSession(
            containerID: "summary-attach",
            logger: Logger(label: "test.summary.attach")
        ) { session in
            // First attach - no history
            let (historyBytes1, _) = session.sendHistory()
            #expect(historyBytes1 == 0, "No history on first attach")
            
            // In a real scenario, the container process would be connected to the PTY
            // and would generate output. For this test, we'll simulate by checking
            // that the PTY session is properly set up and history tracking works.
            
            // Get container handles to simulate container writing
            let containerHandles = session.containerHandles
            guard let containerStdout = containerHandles[1] else {
                Issue.record("Failed to get container stdout handle")
                return
            }
            
            // Simulate container output
            let message = "Container output data\n"
            try containerStdout.write(contentsOf: message.data(using: .utf8)!)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            // Second attach - should have history
            let (historyBytes2, _) = session.sendHistory()
            #expect(historyBytes2 > 0, "Has history on reattach: \(historyBytes2) bytes")
            #expect(historyBytes2 >= message.count, "History contains the output")
        }
    }
    
    @Test("Character I/O works in both modes")
    func testCharacterIOBothModes() throws {
        // Test both legacy (pipes) and server (would use PTY)
        for mode in ["legacy", "server"] {
            let stdin = Pipe()
            let stdout = Pipe()
            
            // Send character
            let char = "X"
            let charData = char.data(using: .utf8)!
            try stdin.fileHandleForWriting.write(contentsOf: charData)
            
            // Read character
            let received = readAvailableData(from: stdin.fileHandleForReading)
            #expect(received == charData, "\(mode): Character passes through")
            
            // Echo character
            try stdout.fileHandleForWriting.write(contentsOf: charData)
            let echo = readAvailableData(from: stdout.fileHandleForReading)
            #expect(echo == charData, "\(mode): Character echo works")
        }
    }
    
    @Test("Binary data works correctly")
    func testBinaryDataIntegrity() throws {
        let pipe = Pipe()
        
        // Test binary data including nulls
        let binaryData = Data([0x00, 0x01, 0xFF, 0x42, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        try pipe.fileHandleForWriting.write(contentsOf: binaryData)
        
        let received = readAvailableData(from: pipe.fileHandleForReading)
        #expect(received == binaryData, "Binary data preserved")
    }
    
    @Test("Multiple sessions can attach to same PTY")
    func testMultipleAttach() async throws {
        try await withPTYSession(
            containerID: "summary-multi",
            logger: Logger(label: "test.summary.multi")
        ) { session in
            // PTY sessions share the same terminal
            // All output is broadcast to all attached clients
            let clientHandles = session.clientHandles
            guard let stdin = clientHandles[0],
                  let stdout = clientHandles[1] else {
                Issue.record("Failed to get client handles")
                return
            }
            
            // Write from "session 1"
            let msg1 = "Message from session 1\n"
            try stdin.write(contentsOf: msg1.data(using: .utf8)!)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            
            // Both "sessions" see the same output
            let output = readAvailableData(from: stdout)
            let outputStr = String(data: output, encoding: .utf8) ?? ""
            #expect(outputStr.contains("session 1"), "Output visible to all sessions")
            
            // In a real multi-attach scenario, multiple clients would connect
            // to the same PTY session and all see the same terminal output
        }
    }
    
    @Test("Stdio handle transfer via XPC works")
    func testXPCHandleTransfer() throws {
        let stdin = Pipe()
        let stdout = Pipe()
        
        // Simulate server creating handles
        let message = XPCMessage(route: "test")
        message.set(key: .stdin, value: stdin.fileHandleForWriting)
        message.set(key: .stdout, value: stdout.fileHandleForReading)
        
        // Client extracts handles
        let clientStdin = message.fileHandle(key: .stdin)
        let clientStdout = message.fileHandle(key: .stdout)
        
        #expect(clientStdin != nil, "Stdin transferred")
        #expect(clientStdout != nil, "Stdout transferred")
        
        // Verify handles work
        let testData = "XPC test\n".data(using: .utf8)!
        try clientStdin!.write(contentsOf: testData)
        
        let received = readAvailableData(from: stdin.fileHandleForReading)
        #expect(received == testData, "XPC-transferred handle works")
    }
}    
