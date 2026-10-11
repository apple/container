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

import ContainerResource
import ContainerXPC
import ContainerizationExtras
import Testing

@testable import ContainerNetworkClient
@testable import ContainerNetworkServer

// The testing library also defines an Attachment type.
private typealias NetworkAttachment = ContainerResource.Attachment

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
        #expect(try message().aliases() == nil)
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

    @Test func testMessageWithoutMatchKindIsAHostnameMatch() throws {
        #expect(try message().matchKind() == .hostname)
    }

    @Test func testUnknownMatchKindIsRejected() throws {
        let message = message()
        message.set(key: NetworkKeys.matchKind.rawValue, value: "wildcard")

        #expect(throws: (any Error).self) {
            try message.matchKind()
        }
    }

    // MARK: - Acknowledgement

    @Test func testAcknowledgementIsNotNeededWithoutAliases() throws {
        try NetworkClient.verifyAliasAcknowledgement(requested: [], acknowledged: nil, plugin: "test-plugin")
        try NetworkClient.verifyAliasAcknowledgement(requested: [], acknowledged: ["unexpected.test"], plugin: "test-plugin")
    }

    @Test func testMatchingAcknowledgementIsAccepted() throws {
        try NetworkClient.verifyAliasAcknowledgement(
            requested: ["api.example.test", ".example.test"],
            acknowledged: ["api.example.test", ".example.test"],
            plugin: "test-plugin"
        )
    }

    @Test func testMissingAcknowledgementIsRejectedWithThePluginName() {
        do {
            try NetworkClient.verifyAliasAcknowledgement(requested: ["api.example.test"], acknowledged: nil, plugin: "test-plugin")
            Issue.record("expected the aliases to be rejected")
        } catch {
            #expect("\(error)".contains("test-plugin"))
        }
    }

    @Test func testDifferentAcknowledgementIsRejected() {
        #expect(throws: (any Error).self) {
            try NetworkClient.verifyAliasAcknowledgement(
                requested: ["api.example.test", "web.example.test"],
                acknowledged: ["api.example.test"],
                plugin: "test-plugin"
            )
        }
    }

    // MARK: - Default NetworkService behavior

    private struct StubError: Error {}

    private struct StubService: NetworkService {
        let attachment: NetworkAttachment?

        func status() async throws -> NetworkStatus { throw StubError() }

        func allocate(
            hostname: String,
            macAddress: MACAddress?,
            session: XPCServerSession
        ) async throws -> (attachment: NetworkAttachment, additionalData: XPCMessage?) {
            throw StubError()
        }

        func lookup(hostname: String) async throws -> NetworkAttachment? { attachment }
    }

    @Test func testDefaultMatchReportsAHostnameMatch() async throws {
        let attachment = NetworkAttachment(
            network: "default",
            hostname: "foo.test.",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )

        let match = try #require(try await StubService(attachment: attachment).match(name: "foo.test."))

        #expect(match.kind == .hostname)
        #expect(match.attachment.hostname == "foo.test.")
    }

    @Test func testDefaultMatchFindsNothingWhenLookupFindsNothing() async throws {
        #expect(try await StubService(attachment: nil).match(name: "foo.test.") == nil)
    }
}
