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

/// Tests for PTY session management XPC protocol
struct TestPTYSessionManagement {
    
    @Test("XPC message handling for attach command")
    func testAttachXPCMessage() throws {
        // Test attach request message
        let attachRequest = XPCMessage(route: SandboxRoutes.attach.rawValue)
        attachRequest.set(key: .sessionId, value: "test-container-789")
        attachRequest.set(key: .sendHistory, value: true)
        
        #expect(attachRequest.string(key: .sessionId) == "test-container-789", "Should have session ID")
        #expect(attachRequest.bool(key: .sendHistory) == true, "Should have sendHistory flag")
        
        // Test attach response with handles
        let attachReply = XPCMessage(route: SandboxRoutes.attach.rawValue)
        
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        attachReply.set(key: .stdin, value: stdinPipe.fileHandleForWriting)
        attachReply.set(key: .stdout, value: stdoutPipe.fileHandleForReading)
        attachReply.set(key: .stderr, value: stderrPipe.fileHandleForReading)
        attachReply.set(key: .historyBytes, value: Int64(1024))
        attachReply.set(key: .truncated, value: false)
        
        // Verify response
        #expect(attachReply.fileHandle(key: .stdin) != nil, "Should have stdin handle")
        #expect(attachReply.fileHandle(key: .stdout) != nil, "Should have stdout handle")
        #expect(attachReply.int64(key: .historyBytes) == 1024, "Should have history bytes count")
        #expect(attachReply.bool(key: .truncated) == false, "Should have truncated flag")
    }
    
    @Test("SandboxClient attach method builds correct XPC message")
    func testSandboxClientAttachMessage() async throws {
        // This test verifies the structure of attach messages
        // We can't test the actual XPC communication without a running service
        
        
        // Verify the attach route exists
        let attachRoute = SandboxRoutes.attach.rawValue
        #expect(attachRoute == "com.apple.container.sandbox/attach", "Attach route should be correctly defined")
        
        // Verify XPC keys exist
        #expect(XPCKeys.sessionId.rawValue == "sessionId", "Session ID key should exist")
        #expect(XPCKeys.sendHistory.rawValue == "sendHistory", "Send history key should exist")
        #expect(XPCKeys.historyBytes.rawValue == "historyBytes", "History bytes key should exist")
        #expect(XPCKeys.truncated.rawValue == "truncated", "Truncated key should exist")
    }
    
    @Test("Attach response stdio array extraction")
    func testAttachResponseHandles() throws {
        // Test extracting stdio handles from attach response
        let reply = XPCMessage(route: SandboxRoutes.attach.rawValue)
        
        // Create test handles
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        // No stderr for PTY mode (combined with stdout)
        
        reply.set(key: .stdin, value: stdinPipe.fileHandleForWriting)
        reply.set(key: .stdout, value: stdoutPipe.fileHandleForReading)
        
        // Extract stdio array as done in SandboxClient.attach
        var stdio: [FileHandle?] = [nil, nil, nil]
        stdio[0] = reply.fileHandle(key: .stdin)
        stdio[1] = reply.fileHandle(key: .stdout)
        stdio[2] = reply.fileHandle(key: .stderr)
        
        #expect(stdio[0] != nil, "Should have stdin handle")
        #expect(stdio[1] != nil, "Should have stdout handle")
        #expect(stdio[2] == nil, "Should not have stderr handle for PTY mode")
    }
    
}