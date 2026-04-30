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

import Foundation
import Testing

class TestCLIStop: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testStopWithExplicitSignal() throws {
        let name = getTestName()
        try doLongRun(name: name)
        defer { try? doStop(name: name) }

        try waitForContainerRunning(name)

        try doStop(name: name, signal: "SIGTERM")
        let status = try getContainerStatus(name)
        #expect(status == "stopped")
    }

    @Test func testStopWithoutSignal() throws {
        let name = getTestName()
        try doLongRun(name: name)
        defer { try? doStop(name: name) }

        try waitForContainerRunning(name)

        try doStop(name: name, signal: nil)
        let status = try getContainerStatus(name)
        #expect(status == "stopped")
    }

    @Test func testStopSignalInInspect() throws {
        let name = getTestName()
        try doLongRun(name: name)
        defer { try? doStop(name: name) }

        try waitForContainerRunning(name)

        let inspect = try inspectContainer(name)
        // Alpine doesn't set a STOPSIGNAL, so this should be nil.
        #expect(inspect.configuration.stopSignal == nil)
    }

    @Test func testStopIdempotent() throws {
        let name = getTestName()
        try doLongRun(name: name)
        defer { try? doStop(name: name) }

        try waitForContainerRunning(name)

        try doStop(name: name, signal: "SIGKILL")
        let status = try getContainerStatus(name)
        #expect(status == "stopped")

        // Stopping an already stopped container should not fail.
        try doStop(name: name, signal: "SIGKILL")
    }
}
