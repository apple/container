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

/// Decides which build-context paths the host can leave out of the context tar
/// because `.dockerignore` excludes them.
///
/// The builder shim applies the exact BuildKit filter (`moby/patternmatcher`)
/// after it unpacks the tar, so this matcher only has to be a conservative
/// subset of it: leaving a path in costs time, but leaving out a path the shim
/// would keep loses a file. The matcher therefore:
///
/// - Parses patterns the way `patternmatcher.New` does (trim whitespace,
///   `filepath.Clean`, a leading `!` marks a negation).
/// - Uses an exclusion pattern only if it contains no `[` or `\`, whose meaning
///   could differ between Go and ICU regular expressions.
/// - Never excludes a path at or beneath which any negation pattern could match,
///   judged by the negation's literal prefix. Negations are then irrelevant for
///   every path it does exclude, so the result does not depend on pattern order.
struct DockerignoreMatcher: Sendable {
    private let exclusions: [NSRegularExpression]
    /// Literal prefix of each negation pattern, up to its first special character.
    private let negationPrefixes: [String]

    init(patterns: [String]) {
        var exclusions: [NSRegularExpression] = []
        var negationPrefixes: [String] = []
        for raw in patterns {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var pattern = Self.clean(trimmed)
            if pattern.hasPrefix("!") {
                pattern.removeFirst()
                // patternmatcher rejects a lone "!"; matching nothing is the safe equivalent.
                guard !pattern.isEmpty else { continue }
                negationPrefixes.append(Self.literalPrefix(of: pattern))
                continue
            }
            if pattern.contains("[") || pattern.contains("\\") {
                continue
            }
            if let regex = try? NSRegularExpression(pattern: Self.regex(for: pattern)) {
                exclusions.append(regex)
            }
        }
        self.exclusions = exclusions
        self.negationPrefixes = negationPrefixes
    }

    /// True when the matcher can never exclude anything.
    var isEmpty: Bool { exclusions.isEmpty }

    /// Returns true if `path` (relative to the context root, `/`-separated) and
    /// everything beneath it can be left out of the context tar.
    func excludes(_ path: String) -> Bool {
        guard !exclusions.isEmpty, !path.isEmpty else { return false }
        let directory = path + "/"
        for prefix in negationPrefixes where prefix.hasPrefix(directory) || directory.hasPrefix(prefix) {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for end in components.indices {
            let candidate = components[...end].joined(separator: "/")
            if exclusions.contains(where: { Self.matches($0, candidate) }) {
                return true
            }
        }
        return false
    }

    private static func matches(_ regex: NSRegularExpression, _ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// The part of `pattern` before its first character that is not matched literally.
    private static func literalPrefix(of pattern: String) -> String {
        String(pattern.prefix { !"*?[\\".contains($0) })
    }

    /// Translates a cleaned pattern without `[` or `\` to a regular expression,
    /// following `patternmatcher`'s `Pattern.compile`.
    static func regex(for pattern: String) -> String {
        var result = "^"
        var chars = Array(pattern)[...]
        while let ch = chars.popFirst() {
            switch ch {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    // "**/" is treated as "**".
                    if chars.first == "/" {
                        chars.removeFirst()
                    }
                    // A trailing "**" matches everything; otherwise "**" spans any number of segments.
                    result += chars.isEmpty ? ".*" : "(.*/)?"
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            default:
                result += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        // `\z` rather than `$`, which in ICU also matches before a trailing newline.
        return result + "\\z"
    }

    /// Lexical path cleaning with the same rules as Go's `path.Clean`.
    static func clean(_ path: String) -> String {
        let rooted = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !rooted {
                    parts.append(part)
                }
            default:
                parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        if rooted {
            return "/" + joined
        }
        return joined.isEmpty ? "." : joined
    }
}
