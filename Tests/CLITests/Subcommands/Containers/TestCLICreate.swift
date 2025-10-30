//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

class TestCLICreateCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testCreateArgsPassthrough() throws {
        let name = getTestName()
        #expect(throws: Never.self, "expected container create to succeed") {
            try doCreate(name: name, args: ["echo", "-n", "hello", "world"])
            try doRemove(name: name)
        }
    }

    @Test func testCreateWithMACAddress() throws {
        let name = getTestName()
        let expectedMAC = "02:42:ac:11:00:03"
        #expect(throws: Never.self, "expected container create with MAC address to succeed") {
            try doCreate(name: name, networks: ["default,mac=\(expectedMAC)"])
            try doStart(name: name)
            defer {
                try? doStop(name: name)
                try? doRemove(name: name)
            }
            try waitForContainerRunning(name)
            let inspectResp = try inspectContainer(name)
            #expect(inspectResp.networks.count > 0, "expected at least one network attachment")
            #expect(inspectResp.networks[0].macAddress == expectedMAC, "expected MAC address \(expectedMAC), got \(inspectResp.networks[0].macAddress ?? "nil")")
        }
    }
}
