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
import Testing

@testable import ContainerNetworkClient
@testable import ContainerNetworkServer

struct NetworkAliasProtocolTests {
    private func message() -> XPCMessage {
        XPCMessage(route: "test")
    }

    // MARK: - Aliases in messages

    @Test func testAliasesRoundTrip() throws {
        let message = message()
        try message.setAliases(["api.example.test", ".example.test"])

        #expect(try message.aliases() == ["api.example.test", ".example.test"])
    }

    @Test func testMessageWithoutAliasesHasNone() throws {
        #expect(try message().aliases().isEmpty)
    }

    // MARK: - Match kind in messages

    @Test func testMatchKindRoundTrip() throws {
        let kinds: [NetworkMatchKind] = [.hostname, .alias, .subtree(baseLabelCount: 3)]
        for kind in kinds {
            let message = message()
            message.setMatchKind(kind)
            #expect(try message.matchKind() == kind)
        }
    }

    @Test func testMessageWithoutMatchKindIsRejected() {
        #expect(throws: (any Error).self) {
            try message().matchKind()
        }
    }

    @Test func testUnknownMatchKindIsRejected() throws {
        let message = message()
        message.set(key: NetworkKeys.matchKind.rawValue, value: "wildcard")

        #expect(throws: (any Error).self) {
            try message.matchKind()
        }
    }

    // MARK: - Name in messages

    @Test func testNameRoundTrip() throws {
        let message = message()
        message.set(key: NetworkKeys.name.rawValue, value: "web.example.test.")

        #expect(try message.name() == "web.example.test.")
    }

    @Test func testMessageWithoutNameIsRejected() {
        #expect(throws: (any Error).self) {
            try message().name()
        }
    }
}
