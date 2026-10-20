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

@Suite("DNSMatchRule")
struct DNSMatchRuleTests {
    // The names used in the tests are valid, so a failure here is a bug in the test itself.
    private func name(_ string: String) -> DNSName {
        try! DNSName(string)
    }

    // MARK: - Parsing

    @Test("Parses an exact rule")
    func parseExact() throws {
        let rule = try DNSMatchRule("api.example.test")
        #expect(rule == .exact(name("api.example.test")))
    }

    @Test("Parses a subtree rule from a leading dot")
    func parseSubtree() throws {
        let rule = try DNSMatchRule(".example.test")
        #expect(rule == .subtree(name("example.test")))
    }

    @Test("Accepts a trailing dot")
    func parseTrailingDot() throws {
        #expect(try DNSMatchRule("api.example.test.") == .exact(name("api.example.test")))
        #expect(try DNSMatchRule(".example.test.") == .subtree(name("example.test")))
    }

    @Test("Lowercases the name")
    func parseLowercases() throws {
        #expect(try DNSMatchRule("API.Example.TEST") == .exact(name("api.example.test")))
        #expect(try DNSMatchRule(".Example.TEST") == .subtree(name("example.test")))
    }

    @Test(
        "The string form is normalized and parses back to the same rule",
        arguments: [
            ("api.example.test", "api.example.test"),
            ("API.Example.test.", "api.example.test"),
            (".example.test", ".example.test"),
            (".Example.TEST.", ".example.test"),
            ("localhost", "localhost"),
        ])
    func descriptionRoundTrip(input: String, expected: String) throws {
        let rule = try DNSMatchRule(input)
        #expect(rule.description == expected)
        #expect(try DNSMatchRule(rule.description) == rule)
    }

    @Test(
        "Rejects invalid rules",
        arguments: [
            "",
            ".",
            "..",
            "..example.test",
            "example..test",
            ".example..test",
            "-example.test",
            "example-.test",
            " example.test",
            "example.test ",
            "exa mple.test",
            String(repeating: "a", count: 64) + ".test",
            String(repeating: "abcdefgh.", count: 30) + "test",
        ])
    func parseInvalid(input: String) {
        #expect(throws: DNSBindError.self) {
            try DNSMatchRule(input)
        }
    }

    @Test(
        "Rejects an asterisk and points to the leading-dot form",
        arguments: ["*.example.test", "*", "api.*.test", "example.*", "*example.test"])
    func parseAsterisk(input: String) {
        do {
            _ = try DNSMatchRule(input)
            Issue.record("expected \(input) to be rejected")
        } catch {
            #expect("\(error)".contains("leading dot"))
        }
    }

    // MARK: - Matching

    @Test("An exact rule matches only that name")
    func exactMatches() throws {
        let rule = try DNSMatchRule("api.example.test")
        #expect(rule.matches(name("api.example.test")))
        #expect(rule.matches(name("API.example.test.")))
        #expect(!rule.matches(name("example.test")))
        #expect(!rule.matches(name("web.api.example.test")))
        #expect(!rule.matches(name("api.example.com")))
    }

    @Test("A subtree rule matches names below the base at one or more labels")
    func subtreeMatchesBelowBase() throws {
        let rule = try DNSMatchRule(".example.test")
        #expect(rule.matches(name("web.example.test")))
        #expect(rule.matches(name("a.b.example.test")))
        #expect(rule.matches(name("WEB.Example.Test.")))
    }

    @Test("A subtree rule does not match its base")
    func subtreeDoesNotMatchBase() throws {
        let rule = try DNSMatchRule(".example.test")
        #expect(!rule.matches(name("example.test")))
    }

    @Test("A subtree rule matches by label and not by string suffix")
    func subtreeMatchesByLabel() throws {
        let rule = try DNSMatchRule(".example.test")
        #expect(!rule.matches(name("evilexample.test")))
        #expect(!rule.matches(name("web.evilexample.test")))
        #expect(!rule.matches(name("example.test.evil")))
    }

    @Test("A subtree rule does not match unrelated or shorter names")
    func subtreeDoesNotMatchUnrelated() throws {
        let rule = try DNSMatchRule(".example.test")
        #expect(!rule.matches(name("web.example.com")))
        #expect(!rule.matches(name("test")))
        #expect(!rule.matches(DNSName()))
    }

    // MARK: - Subtree bases

    @Test("Lists the proper suffixes of a name, longest first")
    func subtreeBases() {
        let bases = DNSMatchRule.subtreeBases(of: name("a.b.example.test"))
        #expect(bases == [name("b.example.test"), name("example.test"), name("test")])
    }

    @Test("A single-label name has no subtree bases")
    func subtreeBasesSingleLabel() {
        #expect(DNSMatchRule.subtreeBases(of: name("test")).isEmpty)
        #expect(DNSMatchRule.subtreeBases(of: DNSName()).isEmpty)
    }

    @Test("Every subtree base of a name matches the name as a subtree rule")
    func subtreeBasesMatch() {
        let queried = name("a.b.example.test")
        for base in DNSMatchRule.subtreeBases(of: queried) {
            #expect(DNSMatchRule.subtree(base).matches(queried))
        }
    }
}
