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

/// A helper class for matching partial strings against a collection of candidates.
/// Used primarily for resolving partial container IDs to full IDs.
public struct StringMatcher {

    /// Represents the result of a match operation
    public enum MatchResult: Equatable {
        case exactMatch(String)
        case singleMatch(String)
        case noMatch
        case multipleMatches([String])
    }

    /// Matches a partial string against a collection of candidates using prefix matching.
    ///
    /// Matching rules:
    /// 1. Exact match takes precedence over prefix match
    /// 2. Prefix matching is case-sensitive
    /// 3. Only prefix matches are considered (no substring matching)
    /// 4. If multiple candidates match, returns ambiguous result
    ///
    /// - Parameters:
    ///   - partial: The partial string to match
    ///   - candidates: The collection of strings to match against
    /// - Returns: A MatchResult indicating the outcome of the match operation
    public static func match(partial: String, candidates: [String]) -> MatchResult {
        var matches: [String] = []
        for candidate in candidates {
            if candidate == partial {
                return .exactMatch(candidate)
            } else {
                if partial.count >= 2 && candidate.hasPrefix(partial) {
                    matches.append(candidate)
                }
            }
        }
        if matches.count == 0 {
            return .noMatch
        } else if matches.count == 1 {
            return .singleMatch(matches[0])
        } else {
            return .multipleMatches(matches)
        }
    }
}
