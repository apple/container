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

@testable import DNSServer

@Suite("AliasPolicy")
struct AliasPolicyTests {
    // The names used in the tests are valid, so a failure here is a bug in the test itself.
    private func name(_ string: String) -> DNSName {
        try! DNSName(string)
    }

    private func validate(_ aliases: [String], hostname: String? = "gateway.test") throws -> [DNSMatchRule] {
        try AliasPolicy.validate(aliases: aliases, hostname: hostname.map { name($0) }, network: "default")
    }

    private func expectViolation(_ text: String, _ aliases: [String], hostname: String? = "gateway.test") {
        do {
            _ = try validate(aliases, hostname: hostname)
            Issue.record("expected \(aliases) to be rejected")
        } catch let violation as AliasPolicy.Violation {
            #expect(violation.description.contains(text), "\(violation)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("No aliases is valid")
    func noAliases() throws {
        #expect(try validate([]).isEmpty)
    }

    @Test("Valid aliases are returned as rules in order")
    func validAliases() throws {
        let rules = try validate(["api.test", ".gateway.test", "Web.Example.Test."])
        #expect(rules == [.exact(name("api.test")), .subtree(name("gateway.test")), .exact(name("web.example.test"))])
    }

    @Test("The limit is applied to the number of aliases")
    func aliasLimit() throws {
        let atLimit = (0..<AliasPolicy.maximumAliasesPerAttachment).map { "alias\($0).test" }
        #expect(try validate(atLimit).count == AliasPolicy.maximumAliasesPerAttachment)
        expectViolation("at most", atLimit + ["one-more.test"])
    }

    @Test("A value that is not a rule is rejected with the alias and the network", arguments: ["", ".", "a..b", "-bad.test", "exa mple.test"])
    func malformed(alias: String) {
        expectViolation("invalid alias \"\(alias)\" for network default", [alias])
    }

    @Test("An asterisk is rejected with a hint about the leading dot")
    func asterisk() {
        expectViolation("leading dot", ["*.gateway.test"])
    }

    @Test("An alias listed twice is rejected")
    func duplicate() {
        expectViolation("more than once", ["api.test", "API.test."])
    }

    @Test("An exact alias needs at least two labels", arguments: ["api", "localhost", "API."])
    func exactNeedsTwoLabels(alias: String) {
        expectViolation("fully qualified", [alias])
    }

    @Test("An exact alias cannot be the hostname of the attachment")
    func exactIsHostname() {
        expectViolation("already a hostname", ["Gateway.Test."])
    }

    @Test("A subtree base needs at least two labels")
    func subtreeNeedsTwoLabels() {
        expectViolation("at least 2 labels", [".test"], hostname: "test")
    }

    @Test("A subtree below the hostname of the attachment is valid")
    func subtreeBelowHostname() throws {
        #expect(try validate([".gateway.test"]).count == 1)
    }

    @Test("A subtree below an exact alias of the attachment is valid")
    func subtreeBelowAlias() throws {
        #expect(try validate([".apps.test", "apps.test"]).count == 2)
    }

    @Test("A subtree below a name that the attachment does not own is rejected")
    func subtreeNotOwned() {
        expectViolation("neither", [".apps.test"])
        expectViolation("neither", [".other.gateway.test"])
    }

    @Test("Without a valid hostname only the exact aliases can be owned")
    func subtreeWithoutHostname() throws {
        expectViolation("neither", [".gateway.test"], hostname: nil)
        #expect(try validate(["apps.test", ".apps.test"], hostname: nil).count == 2)
    }
}
