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

@testable import ContainerBuild

struct DockerignoreMatcherTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let patterns: [String]
        let path: String
        let excluded: Bool

        var testDescription: String { "\(patterns) \(path) -> \(excluded)" }
    }

    // Expected values follow moby/patternmatcher's MatchesOrParentMatches, except
    // where the matcher is deliberately more conservative (noted inline): there it
    // may keep a path the shim would drop, but never the other way around.
    static let cases: [Case] = [
        // Plain names, with and without the cleaning patternmatcher applies.
        Case(patterns: ["ignored"], path: "ignored", excluded: true),
        Case(patterns: ["ignored"], path: "ignored/blob1", excluded: true),
        Case(patterns: ["ignored"], path: "ignored/a/b/c", excluded: true),
        Case(patterns: ["ignored"], path: "ignoredx", excluded: false),
        Case(patterns: ["ignored"], path: "keep", excluded: false),
        Case(patterns: ["ignored"], path: "sub/ignored", excluded: false),
        Case(patterns: ["ignored/"], path: "ignored/blob1", excluded: true),
        Case(patterns: ["./target/"], path: "target/debug", excluded: true),
        Case(patterns: ["  target  "], path: "target", excluded: true),
        Case(patterns: ["a//b/./c/.."], path: "a/b/x", excluded: true),
        // patternmatcher does not strip a leading "/" (BuildKit already does), so it never matches.
        Case(patterns: ["/target"], path: "target", excluded: false),

        // Wildcards.
        Case(patterns: ["*.log"], path: "a.log", excluded: true),
        Case(patterns: ["*.log"], path: "dir/a.log", excluded: false),
        Case(patterns: ["*/*.log"], path: "dir/a.log", excluded: true),
        Case(patterns: ["**/*.log"], path: "dir/sub/a.log", excluded: true),
        Case(patterns: ["**/*.log"], path: "a.log", excluded: true),
        Case(patterns: ["**/target"], path: "target", excluded: true),
        Case(patterns: ["**/target"], path: "a/b/target/x", excluded: true),
        Case(patterns: ["**/target"], path: "a/xtarget", excluded: false),
        Case(patterns: ["dir/**"], path: "dir/x", excluded: true),
        Case(patterns: ["dir/**"], path: "dir", excluded: false),
        Case(patterns: ["dir/**/x"], path: "dir/x", excluded: true),
        Case(patterns: ["dir/**/x"], path: "dir/a/b/x", excluded: true),
        Case(patterns: ["**"], path: "anything/at/all", excluded: true),
        Case(patterns: ["file?"], path: "file1", excluded: true),
        Case(patterns: ["file?"], path: "file", excluded: false),
        Case(patterns: ["a.b"], path: "aXb", excluded: false),
        Case(patterns: ["a+(b)"], path: "a+(b)", excluded: true),
        Case(patterns: ["foo"], path: "foo\n", excluded: false),

        // Negations: never exclude a path at or under which a negation could match.
        Case(patterns: ["ignored", "!ignored/keep"], path: "ignored", excluded: false),
        Case(patterns: ["ignored", "!ignored/keep"], path: "ignored/keep", excluded: false),
        Case(patterns: ["ignored", "!ignored/keep"], path: "ignored/other", excluded: true),
        Case(patterns: ["ignored", "!ignored/keep"], path: "ignored/keepsake", excluded: false),  // conservative
        Case(patterns: ["ignored", "!other/keep"], path: "ignored/x", excluded: true),
        Case(patterns: ["ignored", "!ign*"], path: "ignored/x", excluded: false),  // conservative
        Case(patterns: ["ignored", "!**/keep"], path: "ignored/x", excluded: false),  // conservative
        Case(patterns: ["!ignored/keep", "ignored"], path: "ignored/keep", excluded: false),  // shim: excluded

        // Patterns the matcher does not use, so it never excludes by them.
        Case(patterns: ["a[b]c"], path: "abc", excluded: false),
        Case(patterns: ["a\\*"], path: "a*", excluded: false),
        Case(patterns: [""], path: "x", excluded: false),
        Case(patterns: ["!"], path: "x", excluded: false),
        Case(patterns: ["ignored"], path: "", excluded: false),
    ]

    @Test(arguments: cases)
    func testExcludes(_ c: Case) {
        #expect(DockerignoreMatcher(patterns: c.patterns).excludes(c.path) == c.excluded)
    }

    @Test func testIsEmpty() {
        #expect(DockerignoreMatcher(patterns: []).isEmpty)
        #expect(DockerignoreMatcher(patterns: ["!keep", "a[b]"]).isEmpty)
        #expect(!DockerignoreMatcher(patterns: ["target"]).isEmpty)
    }

    @Test(arguments: [
        ("a//b/./c/../", "a/b"),
        ("./target/", "target"),
        ("../x", "../x"),
        ("/../x", "/x"),
        ("a/../..", ".."),
        ("", "."),
        ("!foo/", "!foo"),
    ])
    func testClean(_ input: String, _ expected: String) {
        #expect(DockerignoreMatcher.clean(input) == expected)
    }

    // MARK: - exclude-patterns metadata

    private func packet(_ metadata: [String: String]) -> BuildTransfer {
        var p = BuildTransfer()
        p.metadata = metadata
        return p
    }

    @Test func testExcludePatternsDecodesQueryEscapedValues() {
        let p = packet(["exclude-patterns": "a%2Cb,c+d,target%2F", "exclude-patterns-encoded": "1"])
        #expect(p.excludePatterns() == ["a,b", "c d", "target/"])
    }

    @Test func testExcludePatternsRequiresEncodedFlag() {
        #expect(packet(["exclude-patterns": "target"]).excludePatterns() == nil)
        #expect(packet(["exclude-patterns": "target", "exclude-patterns-encoded": "0"]).excludePatterns() == nil)
    }

    @Test func testExcludePatternsRejectsInvalidEscapes() {
        #expect(packet(["exclude-patterns": "ok,bad%zz", "exclude-patterns-encoded": "1"]).excludePatterns() == nil)
    }

    @Test func testExcludePatternsMissingOrEmpty() {
        #expect(packet([:]).excludePatterns() == nil)
        #expect(packet(["exclude-patterns": "", "exclude-patterns-encoded": "1"]).excludePatterns() == nil)
    }
}
