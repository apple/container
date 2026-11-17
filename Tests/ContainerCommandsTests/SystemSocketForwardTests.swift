//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

@testable import ContainerCommands

struct SystemSocketForwardTests {
    private func command(host: String = "127.0.0.1", port: Int = 8080, socket: String = "/tmp/service.sock") -> Application.SystemSocketForward {
        var command = Application.SystemSocketForward()
        command.host = host
        command.port = port
        command.socketPath = socket
        return command
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func acceptsNumericLoopback(host: String) throws {
        let command = command(host: host)
        try command.validate()
    }

    @Test(arguments: [-1, 0, 65536])
    func rejectsInvalidPort(port: Int) {
        let command = command(port: port)
        #expect(throws: (any Error).self) { try command.validate() }
    }

    @Test(arguments: ["service.sock", "", String(repeating: "/x", count: 100)])
    func rejectsInvalidSocketPath(socket: String) {
        let command = command(socket: socket)
        #expect(throws: (any Error).self) { try command.validate() }
    }

    @Test
    func rejectsHostnameForListener() {
        let command = command(host: "example.invalid")
        #expect(throws: (any Error).self) { try command.validate() }
    }
}
