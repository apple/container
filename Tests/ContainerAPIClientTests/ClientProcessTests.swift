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

import ContainerXPC
import Darwin
import Testing

@testable import ContainerAPIClient

struct ClientProcessTests {
    @Test
    func killRequestEncodesSignalAsString() throws {
        let request = try ClientProcessImpl.killRequest(
            containerId: "container-id",
            processId: "process-id",
            signal: SIGUSR1
        )

        #expect(request.string(key: XPCMessage.routeKey) == XPCRoute.containerKill.rawValue)
        #expect(request.string(key: .id) == "container-id")
        #expect(request.string(key: .processIdentifier) == "process-id")
        #expect(request.string(key: .signal) == "USR1")
    }

    @Test
    func forwardedSignalsUseLinuxCompatibleNames() throws {
        #expect(try ClientProcessImpl.forwardedSignalName(SIGINT) == "INT")
        #expect(try ClientProcessImpl.forwardedSignalName(SIGTERM) == "TERM")
        #expect(try ClientProcessImpl.forwardedSignalName(SIGWINCH) == "WINCH")
        #expect(try ClientProcessImpl.forwardedSignalName(SIGUSR1) == "USR1")
        #expect(try ClientProcessImpl.forwardedSignalName(SIGUSR2) == "USR2")
    }

    @Test
    func forwardedSignalRejectsUnsupportedSignal() {
        #expect(throws: Error.self) {
            try ClientProcessImpl.forwardedSignalName(Int32.max)
        }
    }
}
