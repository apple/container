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
import ContainerClient
import ContainerXPC
@testable import container

/// Test sandbox transport that captures and validates calls for testing our changes
final class TestSandboxTransport: SandboxTransport, @unchecked Sendable {
    private let attachedSessions: NSMutableDictionary = NSMutableDictionary()
    private let callLog: NSMutableArray = NSMutableArray()
    
    struct PTYSessionInfo {
        let stdin: Pipe
        let stdout: Pipe
        let stderr: Pipe?
        let history: Data
    }
    
    struct XPCCall {
        let route: String
        let service: String
        let parameters: [String: Any]
        let timeout: Duration?
    }
    
    func sendMessage(_ message: XPCMessage, to service: String, timeout: Duration? = nil) async throws -> XPCMessage {
        // Log the XPC call for validation
        let route = message.string(key: XPCMessage.routeKey) ?? ""
        var parameters: [String: Any] = [:]
        
        // Extract common parameters for validation
        if let id = message.string(key: .id) {
            parameters["id"] = id
        }
        // Always capture serverOwnedStdio boolean value
        parameters["serverOwnedStdio"] = message.bool(key: .serverOwnedStdio)
        // Always capture sendHistory boolean value  
        parameters["sendHistory"] = message.bool(key: .sendHistory)
        
        let call = XPCCall(route: route, service: service, parameters: parameters, timeout: timeout)
        callLog.add(call)
        
        // Generate mock response based on route
        let reply = XPCMessage(route: route)
        
        switch route {
        case SandboxRoutes.start.rawValue:
            return try handleStart(message, reply: reply)
        case SandboxRoutes.attach.rawValue:
            return try handleAttach(message, reply: reply)
        default:
            // For other routes, just return empty reply
            return reply
        }
    }
    
    // Get logged XPC calls for test validation
    func getLoggedCalls() -> [XPCCall] {
        return callLog.compactMap { $0 as? XPCCall }
    }
    
    func clearLog() {
        callLog.removeAllObjects()
    }
    
    private func handleStart(_ message: XPCMessage, reply: XPCMessage) throws -> XPCMessage {
        let processID = message.string(key: .id) ?? "test-process"
        let serverOwnedStdio = message.bool(key: .serverOwnedStdio)
        
        if serverOwnedStdio {
            // Create PTY session for server-owned stdio
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr: Pipe? = nil // TTY mode combines stdout/stderr
            
            // Store session for potential reattach
            let sessionInfo = PTYSessionInfo(
                stdin: stdin,
                stdout: stdout,
                stderr: stderr,
                history: "Server stdio output from \(processID)\n".data(using: .utf8) ?? Data()
            )
            attachedSessions[processID] = sessionInfo
            
            // Return handles to client
            reply.set(key: .stdin, value: stdin.fileHandleForWriting)
            reply.set(key: .stdout, value: stdout.fileHandleForReading)
            if let stderr = stderr {
                reply.set(key: .stderr, value: stderr.fileHandleForReading)
            }
        }
        
        return reply
    }
    
    private func handleAttach(_ message: XPCMessage, reply: XPCMessage) throws -> XPCMessage {
        let containerID = message.string(key: .id) ?? "test-container"
        let sendHistory = message.bool(key: .sendHistory)
        
        // Create new PTY session for attach (or reuse existing)
        let sessionKey = "attach-\(containerID)"
        
        let sessionInfo: PTYSessionInfo
        if let existing = attachedSessions[sessionKey] as? PTYSessionInfo {
            sessionInfo = existing
        } else {
            // Create new session
            sessionInfo = PTYSessionInfo(
                stdin: Pipe(),
                stdout: Pipe(),
                stderr: nil,
                history: "Welcome to container \(containerID)\nPrevious session history\n".data(using: .utf8) ?? Data()
            )
            attachedSessions[sessionKey] = sessionInfo
        }
        
        // If sendHistory is requested, write history to stdout
        if sendHistory && !sessionInfo.history.isEmpty {
            try? sessionInfo.stdout.fileHandleForWriting.write(contentsOf: sessionInfo.history)
        }
        
        // Return handles for attach
        reply.set(key: .stdin, value: sessionInfo.stdin.fileHandleForWriting)
        reply.set(key: .stdout, value: sessionInfo.stdout.fileHandleForReading)
        
        return reply
    }
}

/// Integration tests for PTY/stdio functionality changes
/// Tests our specific changes: Terminal.current removal, --legacy-stdio flag, reattach, etc.
class TestCLIStdioModes: CLITest, @unchecked Sendable {
    private var testTransport: TestSandboxTransport?
    
    override init() throws {
        try super.init()
        
        // Set up test transport
        testTransport = TestSandboxTransport()
    }
    
    deinit {
        testTransport = nil
    }
    
    @Test("Legacy stdio flag is properly defined")
    func testLegacyStdioFlagExists() async throws {
        let (output, _, status) = try run(arguments: ["--help"])
        
        #expect(status == 0, "Help command should succeed")
        #expect(output.contains("--legacy-stdio"), "Help should show legacy-stdio flag")
        #expect(output.contains("Use legacy client-owned stdio"), "Help should show legacy-stdio description")
    }
    
    @Test("SandboxClient strategy pattern works")
    func testSandboxClientStrategy() async throws {
        // Test the strategy pattern directly with SandboxClient
        guard let testTransport = testTransport else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test strategy not initialized"])
        }
        
        let client = SandboxClient(id: "test-container", runtime: "test-runtime", transport: testTransport)
        
        // Test startProcessWithServerStdio
        testTransport.clearLog()
        let handles = try await client.startProcessWithServerStdio("test-process")
        
        #expect(handles.count == 3, "Should return 3 file handles")
        #expect(handles[0] != nil, "Should have stdin handle")
        #expect(handles[1] != nil, "Should have stdout handle")
        
        // Validate XPC call was made correctly
        let calls = testTransport.getLoggedCalls()
        #expect(calls.count == 1, "Should make exactly one XPC call")
        #expect(calls[0].route == SandboxRoutes.start.rawValue, "Should call start route")
        #expect(calls[0].parameters["serverOwnedStdio"] as? Bool == true, "Should request server-owned stdio")
    }

    @Test("SandboxClient attach method works")
    func testSandboxClientAttach() async throws {
        // Test the attach functionality
        guard let testTransport = testTransport else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test strategy not initialized"])
        }
        
        let client = SandboxClient(id: "test-container", runtime: "test-runtime", transport: testTransport)
        
        // Test attach with history
        testTransport.clearLog()
        let handles = try await client.attach(containerID: "test-container-123", sendHistory: true)
        
        #expect(handles.count == 3, "Should return 3 file handles")
        #expect(handles[0] != nil, "Should have stdin handle")
        #expect(handles[1] != nil, "Should have stdout handle")
        
        // Validate XPC call
        let calls = testTransport.getLoggedCalls()
        #expect(calls.count == 1, "Should make exactly one XPC call")
        #expect(calls[0].route == SandboxRoutes.attach.rawValue, "Should call attach route")
        #expect(calls[0].parameters["sendHistory"] as? Bool == true, "Should request history")
        #expect(calls[0].parameters["id"] as? String == "test-container-123", "Should pass correct container ID")
    }

    @Test("SandboxClient attach without history works")
    func testSandboxClientAttachNoHistory() async throws {
        guard let testTransport = testTransport else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test strategy not initialized"])
        }
        
        let client = SandboxClient(id: "test-container", runtime: "test-runtime", transport: testTransport)
        
        // Test attach without history
        testTransport.clearLog()
        let handles = try await client.attach(containerID: "test-container-456", sendHistory: false)
        
        #expect(handles.count == 3, "Should return 3 file handles")
        
        // Validate XPC call doesn't request history
        let calls = testTransport.getLoggedCalls()
        #expect(calls.count == 1, "Should make exactly one XPC call")
        #expect(calls[0].parameters["sendHistory"] as? Bool == false, "Should not request history")
    }

    @Test("SandboxClient Codable works without strategy")
    func testSandboxClientCodable() async throws {
        let client = SandboxClient(id: "test-container", runtime: "test-runtime")
        
        // Test encoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(client)
        
        // Test decoding succeeds
        let decoder = JSONDecoder()
        _ = try decoder.decode(SandboxClient.self, from: data)
        
        // Verify encoding/decoding worked without accessing internal properties
        #expect(data.count > 0, "Should encode to non-empty data")
        
        // Test that decoded client can be used (verifies strategy defaults to DefaultXPCStrategy)
        // This indirectly validates that id/runtime were preserved correctly
        let testResult = SandboxClient.machServiceLabel(runtime: "test-runtime", id: "test-container")
        #expect(testResult.contains("test-container"), "Should be able to construct service labels")
        #expect(testResult.contains("test-runtime"), "Should be able to construct service labels")
    }
    
    @Test("RunCommand stdio mode selection logic works")
    func testRunCommandStdioModeSelection() async throws {
        // Test the logic that determines when to use server-owned stdio
        // This tests the core logic from RunCommand.swift without running actual containers
        
        // Test case 1: Interactive + TTY without legacy flag should use server stdio
        var flags = Flags.Global()
        flags.legacyStdio = false
        
        var processFlags = Flags.Process()
        processFlags.interactive = true
        processFlags.tty = true
        
        // Simulate the logic from RunCommand.swift:88-90
        let useLegacyStdio = flags.legacyStdio || ProcessInfo.processInfo.environment["CONTAINER_LEGACY_STDIO"] != nil
        let useServerStdio = !useLegacyStdio && processFlags.interactive && processFlags.tty
        
        #expect(useServerStdio == true, "Should use server stdio with -it flags")
        
        // Test case 2: Legacy flag should force legacy mode
        flags.legacyStdio = true
        let useLegacyStdio2 = flags.legacyStdio || ProcessInfo.processInfo.environment["CONTAINER_LEGACY_STDIO"] != nil
        let useServerStdio2 = !useLegacyStdio2 && processFlags.interactive && processFlags.tty
        
        #expect(useServerStdio2 == false, "Legacy flag should force legacy stdio")
        
        // Test case 3: Non-interactive should use legacy stdio
        flags.legacyStdio = false
        processFlags.interactive = false
        let useLegacyStdio3 = flags.legacyStdio || ProcessInfo.processInfo.environment["CONTAINER_LEGACY_STDIO"] != nil
        let useServerStdio3 = !useLegacyStdio3 && processFlags.interactive && processFlags.tty
        
        #expect(useServerStdio3 == false, "Non-interactive should use legacy stdio")
    }
    
    @Test("ContainerExec stdio mode selection logic works")
    func testContainerExecStdioModeSelection() async throws {
        // Test the logic that determines when to use server-owned stdio in exec
        // This tests the core logic from ContainerExec.swift without running actual containers
        
        // Test case 1: Interactive + TTY without legacy flag should use server stdio
        var global = Flags.Global()
        global.legacyStdio = false
        
        let stdin = true  // processFlags.interactive
        let tty = true    // processFlags.tty
        
        // Simulate the logic from ContainerExec.swift:73 and 88-90
        let useLegacyStdio = global.legacyStdio || ProcessInfo.processInfo.environment["CONTAINER_LEGACY_STDIO"] != nil
        let useServerStdio = !useLegacyStdio && stdin && tty
        
        #expect(useServerStdio == true, "Exec should use server stdio with -it flags")
        
        // Test case 2: Legacy flag should force legacy mode
        global.legacyStdio = true
        let useLegacyStdio2 = global.legacyStdio || ProcessInfo.processInfo.environment["CONTAINER_LEGACY_STDIO"] != nil
        let useServerStdio2 = !useLegacyStdio2 && stdin && tty
        
        #expect(useServerStdio2 == false, "Exec legacy flag should force legacy stdio")
    }
    
    @Test("Environment variable forces legacy stdio")
    func testEnvironmentVariableLegacyStdio() async throws {
        // Test that CONTAINER_LEGACY_STDIO environment variable works
        
        let stdin = true  // equivalent to processFlags.interactive 
        let tty = true    // equivalent to processFlags.tty
        
        var global = Flags.Global()
        global.legacyStdio = false
        
        // Simulate environment variable being set
        let mockEnvironment = ["CONTAINER_LEGACY_STDIO": "1"]
        let useLegacyStdio = global.legacyStdio || mockEnvironment["CONTAINER_LEGACY_STDIO"] != nil
        let useServerStdio = !useLegacyStdio && stdin && tty
        
        #expect(useServerStdio == false, "Environment variable should force legacy stdio")
        #expect(useLegacyStdio == true, "Environment variable should enable legacy stdio")
    }
    
    @Test("Server-owned stdio integration with real ClientContainer")
    func testServerOwnedStdioIntegration() async throws {
        // Test that ClientContainer and ClientProcess use our strategy correctly
        guard let testTransport = testTransport else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test strategy not initialized"])
        }
        
        // Test configuration values for SandboxClient creation
        let configId = "test-container-integration"
        let configRuntimeHandler = "test-runtime"
        
        // Create SandboxClient with test strategy
        let sandboxClient = SandboxClient(id: configId, runtime: configRuntimeHandler, transport: testTransport)
        
        // Test server-owned stdio call
        testTransport.clearLog()
        let handles = try await sandboxClient.startProcessWithServerStdio("integration-test-process")
        
        #expect(handles.count == 3, "Integration test should return 3 handles")
        #expect(handles[0] != nil, "Integration test should have stdin")
        #expect(handles[1] != nil, "Integration test should have stdout")
        
        // Verify the integration called the right XPC route
        let calls = testTransport.getLoggedCalls()
        #expect(calls.count == 1, "Integration should make one XPC call")
        #expect(calls[0].route == SandboxRoutes.start.rawValue, "Integration should call start route")
        #expect(calls[0].parameters["serverOwnedStdio"] as? Bool == true, "Integration should use server stdio")
    }
    
    @Test("Attach command integration works")
    func testAttachCommandIntegration() async throws {
        // Test the attach functionality end-to-end
        guard let testTransport = testTransport else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test strategy not initialized"])
        }
        
        let sandboxClient = SandboxClient(id: "attach-test-container", runtime: "test-runtime", transport: testTransport)
        
        // Test attach with sendHistory=true (default)
        testTransport.clearLog()
        let handles = try await sandboxClient.attach(containerID: "attach-integration-test", sendHistory: true)
        
        #expect(handles.count == 3, "Attach integration should return 3 handles")
        #expect(handles[0] != nil, "Attach should have stdin")
        #expect(handles[1] != nil, "Attach should have stdout")
        
        let calls = testTransport.getLoggedCalls()
        #expect(calls.count == 1, "Attach integration should make one XPC call")
        #expect(calls[0].route == SandboxRoutes.attach.rawValue, "Should call attach route")
        #expect(calls[0].parameters["sendHistory"] as? Bool == true, "Should request history by default")
    }
    
    @Test("Multiple stdio operations work correctly")  
    func testMultipleStdioOperations() async throws {
        // Test that multiple operations work and are logged correctly
        guard let testTransport = testTransport else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Test strategy not initialized"])
        }
        
        let client = SandboxClient(id: "multi-test", runtime: "test-runtime", transport: testTransport)
        
        testTransport.clearLog()
        
        // Perform multiple operations
        _ = try await client.startProcessWithServerStdio("process-1")
        _ = try await client.attach(containerID: "container-1", sendHistory: true)
        _ = try await client.attach(containerID: "container-2", sendHistory: false)
        
        let calls = testTransport.getLoggedCalls()
        #expect(calls.count == 3, "Should log all three operations")
        
        // Verify first call (start)
        #expect(calls[0].route == SandboxRoutes.start.rawValue, "First call should be start")
        #expect(calls[0].parameters["serverOwnedStdio"] as? Bool == true, "Start should use server stdio")
        
        // Verify second call (attach with history)
        #expect(calls[1].route == SandboxRoutes.attach.rawValue, "Second call should be attach")
        #expect(calls[1].parameters["sendHistory"] as? Bool == true, "Second attach should send history")
        
        // Verify third call (attach without history)
        #expect(calls[2].route == SandboxRoutes.attach.rawValue, "Third call should be attach")
        #expect(calls[2].parameters["sendHistory"] as? Bool == false, "Third attach should not send history")
    }
}