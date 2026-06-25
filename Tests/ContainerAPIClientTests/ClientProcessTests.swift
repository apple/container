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

struct ClientProcessTests {
    @Test func signalNameMapsForwardedSignalsToServerFormat() {
        #expect(ClientProcessImpl.signalName(for: SIGTERM) == "SIGTERM")
        #expect(ClientProcessImpl.signalName(for: SIGINT) == "SIGINT")
        #expect(ClientProcessImpl.signalName(for: SIGUSR1) == "SIGUSR1")
        #expect(ClientProcessImpl.signalName(for: SIGUSR2) == "SIGUSR2")
        #expect(ClientProcessImpl.signalName(for: SIGWINCH) == "SIGWINCH")
    }

    @Test func signalNameFallsBackToNumericString() {
        #expect(ClientProcessImpl.signalName(for: 12345) == "12345")
    }
}
