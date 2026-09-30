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

import Darwin
import Testing

@testable import ContainerAPIClient

struct ProcessIOTests {
    @Test("Forwarded process signals are encoded as names")
    func forwardedSignalNames() {
        #expect(ProcessIO.signalName(SIGTERM) == "SIGTERM")
        #expect(ProcessIO.signalName(SIGINT) == "SIGINT")
        #expect(ProcessIO.signalName(SIGUSR1) == "SIGUSR1")
        #expect(ProcessIO.signalName(SIGUSR2) == "SIGUSR2")
    }

    @Test("Terminal resize signal is handled by the resize path")
    func terminalResizeSignalIsNotForwardedAsKill() {
        #expect(!ProcessIO.signalSet.contains(SIGWINCH))
    }
}
