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

import Containerization
import Darwin
import Testing

/// Guards the client -> server signal contract that `ClientProcess.kill(_:)`
/// depends on. The client holds a raw host (macOS) signal number and must put a
/// value on the wire that the server resolves back to the intended signal via
/// `Signal(_:)` (default Linux table), matching `RuntimeService.kill`.
///
/// Regression coverage for the "missing signal in xpc message" bug where the
/// client sent a bare integer that the server read as a string (issues #1941,
/// #1876, #1747).
struct SignalWireFormatTests {
    /// Exactly the expression `ClientProcess.kill(_:)` puts on the wire.
    private func wireValue(_ signal: Int32) -> String {
        Signal.platformName(signal) ?? "\(signal)"
    }

    /// Exactly how the server resolves it (see `RuntimeService.kill`).
    private func resolved(_ signal: Int32) throws -> Int32 {
        try Signal(wireValue(signal)).rawValue
    }

    @Test func commonSignalsRoundTrip() throws {
        // Signals that share a number across macOS and Linux.
        #expect(try resolved(SIGINT) == 2)  // ^C  (#1876)
        #expect(try resolved(SIGWINCH) == 28)  // terminal resize (#1747)
        #expect(try resolved(SIGKILL) == 9)
        #expect(try resolved(SIGTERM) == 15)
        #expect(try resolved(SIGHUP) == 1)
    }

    @Test func platformDivergentSignalTranslatesByName() throws {
        // macOS SIGUSR1 == 30, Linux SIGUSR1 == 10. Sending the name (not the
        // raw number) is what keeps this correct: a raw "30" would land on the
        // container as Linux signal 30 (SIGPWR).
        #expect(SIGUSR1 == 30)
        #expect(wireValue(SIGUSR1) == "USR1")
        #expect(try resolved(SIGUSR1) == 10)
    }

    @Test func nonEmptyWireValue() {
        // The original bug delivered an empty/absent string. Whatever we send
        // must be a non-empty string the server can parse.
        #expect(!wireValue(SIGINT).isEmpty)
        #expect((try? Signal(wireValue(SIGINT))) != nil)
    }
}
