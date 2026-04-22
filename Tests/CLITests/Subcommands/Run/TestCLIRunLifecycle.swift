//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerizationError
import Darwin
import Foundation
import Testing

class TestCLIRunLifecycle: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testRunFailureCleanup() throws {
        let name = getTestName()

        // try to create a container we know will fail
        let badArgs: [String] = [
            "--rm",
            "--user",
            name,
        ]
        #expect(throws: CLIError.self, "expect container to fail with invalid user") {
            try self.doLongRun(name: name, args: badArgs)
        }

        // try to create a container with the same name but no user that should succeed
        #expect(throws: Never.self, "expected container run to succeed") {
            try self.doLongRun(name: name, args: [])
            defer {
                try? self.doStop(name: name)
            }
            let _ = try self.doExec(name: name, cmd: ["date"])
            try self.doStop(name: name)
        }
    }

    @Test func testStartIdempotent() throws {
        let name = getTestName()

        #expect(throws: Never.self, "expected container run to succeed") {
            try self.doLongRun(name: name, args: [])
            defer {
                try? self.doStop(name: name)
            }
            try self.waitForContainerRunning(name)

            let (_, output, _, status) = try self.run(arguments: ["start", name])
            #expect(status == 0, "expected start to succeed on already running container")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == name, "expected output to be container name")

            // Don't care about the resp, just that the container is still there and not cleaned up.
            let _ = try inspectContainer(name)

            try self.doStop(name: name)
        }
    }

    @Test func testStartIdempotentAttachFails() throws {
        let name = getTestName()

        #expect(throws: Never.self, "expected container run to succeed") {
            try self.doLongRun(name: name, args: [])
            defer {
                try? self.doStop(name: name)
            }
            try self.waitForContainerRunning(name)

            let (_, _, error, status) = try self.run(arguments: ["start", "-a", name])
            #expect(status != 0, "expected start with attach to fail on already running container")
            #expect(error.contains("attach is currently unsupported on already running containers"), "expected error message about attach not supported")

            try self.doStop(name: name)
        }
    }

    @Test func testStartPortBindFails() async throws {
        let port = UInt16.random(in: 50000..<60000)

        let name = getTestName()
        try self.doCreate(name: name, ports: ["\(port)"])
        defer {
            try? self.doRemove(name: name)
        }

        let server = "\(name)-server"
        try doLongRun(
            name: server,
            image: "docker.io/library/python:alpine",
            args: ["--publish", "\(port):\(port)"],
            containerArgs: ["python3", "-m", "http.server", "\(port)"]
        )
        defer {
            try? doStop(name: server)
        }

        #expect(throws: CLIError.self) {
            try doStart(name: name)
        }

        let status = try getContainerStatus(name)
        #expect(status == "stopped")
    }

    @Test func testRunInvalidExcutable() async throws {
        let name = getTestName()
        #expect(throws: CLIError.self, "running invalid executable must throw error, not hang") {
            try doLongRun(
                name: name,
                containerArgs: ["foobarbaz"]
            )
        }
        try? doRemove(name: name)
    }

    @Test func testExecInvalidExcutable() async throws {
        let name = getTestName()
        try doLongRun(name: name)
        defer {
            try? doStop(name: name)
        }

        #expect(throws: CLIError.self, "executing invalid executable must throw error, not hang") {
            try doExec(
                name: name,
                cmd: ["foobarbaz"]
            )
        }
    }

    @Test func testSSHForwarding() throws {
        let name = getTestName()

        // Create a temp dir and socket path for the simulated SSH agent.
        let socketDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socketDir) }

        let socketPath = socketDir.appendingPathComponent("ssh-auth.sock").path

        // Create a listening Unix domain socket to act as a fake SSH agent.
        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(serverFd >= 0, "socket() failed")
        defer { Darwin.close(serverFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
            socketPath.withCString { cStr in
                bytes.copyMemory(from: UnsafeRawBufferPointer(start: cStr, count: socketPath.utf8.count + 1))
            }
        }
        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bindResult == 0, "bind() failed: \(errno)")
        precondition(listen(serverFd, 5) == 0, "listen() failed")

        // Accept and immediately close connections in background to keep the socket alive.
        let acceptThread = Thread {
            while true {
                let clientFd = accept(serverFd, nil, nil)
                if clientFd < 0 { break }
                Darwin.close(clientFd)
            }
        }
        acceptThread.start()

        defer { try? doStop(name: name) }

        try doLongRun(name: name, args: ["--ssh"], env: ["SSH_AUTH_SOCK": socketPath])
        try waitForContainerRunning(name)

        // Verify SSH_AUTH_SOCK is set to the expected guest path inside the container.
        let sshSockValue = try doExec(name: name, cmd: ["sh", "-c", "echo $SSH_AUTH_SOCK"])
        #expect(
            sshSockValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/var/host-services/ssh-auth.sock",
            "expected SSH_AUTH_SOCK to point to guest socket path"
        )

        // Verify the forwarded socket file is present and is a socket.
        let socketCheck = try doExec(
            name: name,
            cmd: ["sh", "-c", "[ -S /var/host-services/ssh-auth.sock ] && echo exists || echo missing"]
        )
        #expect(
            socketCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "exists",
            "expected forwarded SSH socket to exist in container"
        )

        try doStop(name: name)
    }
}
