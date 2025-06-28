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

/// Tests for server-owned stdio in SandboxClient
struct TestSandboxClientServerStdio {
    
    @Test("XPC message includes serverOwnedStdio flag")
    func testXPCMessageServerOwnedStdioFlag() throws {
        let message = XPCMessage(route: SandboxRoutes.start.rawValue)
        message.set(key: .id, value: "test-process-123")
        message.set(key: .serverOwnedStdio, value: true)
        
        // Verify the message contains the flag
        #expect(message.bool(key: .serverOwnedStdio) == true, "Message should contain serverOwnedStdio flag")
        #expect(message.string(key: .id) == "test-process-123", "Message should contain process ID")
    }
    
    @Test("XPC reply contains stdio handles")
    func testXPCReplyStdioHandles() throws {
        let reply = XPCMessage(route: SandboxRoutes.start.rawValue)
        
        // Create test file handles
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        // Set handles in reply
        reply.set(key: .stdin, value: stdinPipe.fileHandleForWriting)
        reply.set(key: .stdout, value: stdoutPipe.fileHandleForReading)
        reply.set(key: .stderr, value: stderrPipe.fileHandleForReading)
        
        // Verify handles can be retrieved
        let stdin = reply.fileHandle(key: .stdin)
        let stdout = reply.fileHandle(key: .stdout)
        let stderr = reply.fileHandle(key: .stderr)
        
        #expect(stdin != nil, "Should retrieve stdin handle")
        #expect(stdout != nil, "Should retrieve stdout handle")
        #expect(stderr != nil, "Should retrieve stderr handle")
    }
    
    @Test("Test stdio array extraction from XPC reply")
    func testStdioArrayExtraction() throws {
        let reply = XPCMessage(route: SandboxRoutes.start.rawValue)
        
        // Create test handles
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        
        // Set only some handles (stderr is nil for TTY mode)
        reply.set(key: .stdin, value: stdinPipe.fileHandleForWriting)
        reply.set(key: .stdout, value: stdoutPipe.fileHandleForReading)
        
        // Extract stdio array as done in startProcessWithServerStdio
        var stdio: [FileHandle?] = [nil, nil, nil]
        stdio[0] = reply.fileHandle(key: .stdin)
        stdio[1] = reply.fileHandle(key: .stdout)
        stdio[2] = reply.fileHandle(key: .stderr)
        
        #expect(stdio[0] != nil, "Should have stdin handle")
        #expect(stdio[1] != nil, "Should have stdout handle")
        #expect(stdio[2] == nil, "Should not have stderr handle for TTY mode")
    }
}