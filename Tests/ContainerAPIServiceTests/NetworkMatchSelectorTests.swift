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

import ContainerNetworkClient
import ContainerResource
import ContainerizationExtras
import Testing

@testable import ContainerAPIService

// The testing library also defines an Attachment type.
private typealias NetworkAttachment = ContainerResource.Attachment

struct NetworkMatchSelectorTests {
    // Each match is identified by the network that reported it.
    private func match(_ network: String, _ kind: NetworkMatchKind) throws -> NetworkMatch {
        NetworkMatch(
            attachment: NetworkAttachment(
                network: network,
                hostname: "foo.test",
                ipv4Address: try CIDRv4("192.168.64.2/24"),
                ipv4Gateway: try IPv4Address("192.168.64.1"),
                ipv6Address: nil,
                macAddress: nil
            ),
            kind: kind
        )
    }

    @Test func testNothingOfferedSelectsNothing() {
        #expect(NetworkMatchSelector().best == nil)
    }

    @Test func testHostnameIsDecisive() throws {
        var selector = NetworkMatchSelector()

        #expect(selector.offer(try match("a", .hostname)))
        #expect(selector.best?.attachment.network == "a")
    }

    @Test func testExactAliasIsDecisive() throws {
        var selector = NetworkMatchSelector()

        #expect(selector.offer(try match("a", .alias)))
        #expect(selector.best?.attachment.network == "a")
    }

    @Test func testSubtreeIsNotDecisive() throws {
        var selector = NetworkMatchSelector()

        #expect(!selector.offer(try match("a", .subtree(baseLabelCount: 2))))
        #expect(selector.best?.attachment.network == "a")
    }

    @Test func testLongerSubtreeReplacesShorter() throws {
        var selector = NetworkMatchSelector()

        selector.offer(try match("short", .subtree(baseLabelCount: 2)))
        selector.offer(try match("long", .subtree(baseLabelCount: 3)))

        #expect(selector.best?.attachment.network == "long")
    }

    @Test func testShorterSubtreeDoesNotReplaceLonger() throws {
        var selector = NetworkMatchSelector()

        selector.offer(try match("long", .subtree(baseLabelCount: 3)))
        selector.offer(try match("short", .subtree(baseLabelCount: 2)))

        #expect(selector.best?.attachment.network == "long")
    }

    @Test func testSubtreeOfEqualLengthKeepsTheFirst() throws {
        var selector = NetworkMatchSelector()

        selector.offer(try match("first", .subtree(baseLabelCount: 2)))
        selector.offer(try match("second", .subtree(baseLabelCount: 2)))

        #expect(selector.best?.attachment.network == "first")
    }

    @Test func testHostnameAfterSubtreeWins() throws {
        var selector = NetworkMatchSelector()

        #expect(!selector.offer(try match("subtree", .subtree(baseLabelCount: 4))))
        #expect(selector.offer(try match("exact", .hostname)))

        #expect(selector.best?.attachment.network == "exact")
    }

    @Test func testExactAliasAfterSubtreeWins() throws {
        var selector = NetworkMatchSelector()

        selector.offer(try match("subtree", .subtree(baseLabelCount: 4)))
        selector.offer(try match("alias", .alias))

        #expect(selector.best?.attachment.network == "alias")
    }

    @Test func testSubtreeSelectionDoesNotDependOnTheOrderNetworksAreAsked() throws {
        let matches = [
            try match("one", .subtree(baseLabelCount: 2)),
            try match("two", .subtree(baseLabelCount: 4)),
            try match("three", .subtree(baseLabelCount: 3)),
        ]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

        for order in orders {
            var selector = NetworkMatchSelector()
            for index in order {
                selector.offer(matches[index])
            }
            #expect(selector.best?.attachment.network == "two", "order \(order)")
        }
    }

    @Test func testSubtreeAfterADecisiveMatchDoesNotReplaceIt() throws {
        var selector = NetworkMatchSelector()

        selector.offer(try match("exact", .hostname))
        #expect(selector.offer(try match("subtree", .subtree(baseLabelCount: 5))))

        #expect(selector.best?.attachment.network == "exact")
    }

    // MARK: - Selecting from sources

    private struct SourceError: Error {}

    /// Records which sources were asked.
    private final class Asked: @unchecked Sendable {
        var names = [String]()
    }

    private func source(
        _ name: String,
        asked: Asked,
        _ result: @escaping @Sendable () throws -> NetworkMatch?
    ) -> (name: String, match: @Sendable () async throws -> NetworkMatch?) {
        (
            name: name,
            match: {
                asked.names.append(name)
                return try result()
            }
        )
    }

    @Test func testSelectReturnsTheBestSubtreeFromAllSources() async throws {
        let asked = Asked()
        let short = try match("short", .subtree(baseLabelCount: 2))
        let long = try match("long", .subtree(baseLabelCount: 4))

        let selected = await NetworkMatchSelector.select(
            from: [
                source("a", asked: asked) { short },
                source("b", asked: asked) { nil },
                source("c", asked: asked) { long },
            ],
            onFailure: { _, _ in }
        )

        #expect(selected?.attachment.network == "long")
        #expect(asked.names == ["a", "b", "c"])
    }

    @Test func testSelectStopsAtTheFirstDecisiveMatch() async throws {
        let asked = Asked()
        let subtree = try match("subtree", .subtree(baseLabelCount: 3))
        let exact = try match("exact", .alias)

        let selected = await NetworkMatchSelector.select(
            from: [
                source("a", asked: asked) { subtree },
                source("b", asked: asked) { exact },
                source("c", asked: asked) { throw SourceError() },
            ],
            onFailure: { _, _ in }
        )

        #expect(selected?.attachment.network == "exact")
        #expect(asked.names == ["a", "b"])
    }

    @Test func testSelectSkipsASourceThatFailsAndReportsIt() async throws {
        let asked = Asked()
        let exact = try match("exact", .hostname)
        let failures = Asked()

        let selected = await NetworkMatchSelector.select(
            from: [
                source("broken", asked: asked) { throw SourceError() },
                source("good", asked: asked) { exact },
            ],
            onFailure: { name, _ in failures.names.append(name) }
        )

        #expect(selected?.attachment.network == "exact")
        #expect(failures.names == ["broken"])
    }

    @Test func testSelectReturnsNothingWhenEverySourceFailsOrHasNoMatch() async throws {
        let asked = Asked()

        let selected = await NetworkMatchSelector.select(
            from: [
                source("broken", asked: asked) { throw SourceError() },
                source("empty", asked: asked) { nil },
            ],
            onFailure: { _, _ in }
        )

        #expect(selected == nil)
        #expect(asked.names == ["broken", "empty"])
    }

    @Test func testSelectWithNoSourcesReturnsNothing() async {
        let selected = await NetworkMatchSelector.select(from: [], onFailure: { _, _ in })

        #expect(selected == nil)
    }
}
