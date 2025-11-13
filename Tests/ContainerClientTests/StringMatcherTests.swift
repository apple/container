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

import XCTest

@testable import ContainerClient

/// Tests for StringMatcher partial ID matching functionality
///
/// Matching Rules:
/// - 0 characters (empty): Always `.noMatch`
/// - 1 character: Only exact match (no prefix matching)
/// - 2+ characters: Full matching logic (exact first, then prefix)
final class StringMatcherTests: XCTestCase {

    // MARK: - Exact Match Tests

    /// Test that exact match overrides prefix ambiguity
    /// Given: candidates ["A", "ABCD", "ABEF"]
    /// When: matching "A"
    /// Then: should return exactMatch("A") even though "ABCD" and "ABEF" also start with "A"
    func testExactMatchOverridesPrefixAmbiguity() {
        let candidates = ["A", "ABCD", "ABEF"]
        let result = StringMatcher.match(partial: "A", candidates: candidates)

        if case .exactMatch(let matched) = result {
            XCTAssertEqual(matched, "A")
        } else {
            XCTFail("Expected exactMatch but got \(result)")
        }
    }

    /// Test exact match when it's the only candidate
    func testExactMatchSingleCandidate() {
        let candidates = ["ABCD-1234"]
        let result = StringMatcher.match(partial: "ABCD-1234", candidates: candidates)

        if case .exactMatch(let matched) = result {
            XCTAssertEqual(matched, "ABCD-1234")
        } else {
            XCTFail("Expected exactMatch but got \(result)")
        }
    }

    /// Test exact match with full UUID
    func testExactMatchFullUUID() {
        let candidates = ["550e8400-e29b-41d4-a716-446655440000", "661f9511-f3ac-52e5-b827-557766551111"]
        let fullID = "550e8400-e29b-41d4-a716-446655440000"
        let result = StringMatcher.match(partial: fullID, candidates: candidates)

        if case .exactMatch(let matched) = result {
            XCTAssertEqual(matched, fullID)
        } else {
            XCTFail("Expected exactMatch but got \(result)")
        }
    }

    // MARK: - Single Character Special Cases

    /// Test single character with exact match should return exactMatch
    /// Rule: Single character only matches exactly, no prefix matching
    func testSingleCharacter_ExactMatch() {
        let candidates = ["A", "ABCD", "ABEF"]
        let result = StringMatcher.match(partial: "A", candidates: candidates)

        if case .exactMatch(let matched) = result {
            XCTAssertEqual(matched, "A")
        } else {
            XCTFail("Expected exactMatch('A') but got \(result)")
        }
    }

    /// Test single character without exact match should return noMatch (no prefix matching)
    /// Rule: Single character does NOT do prefix matching
    func testSingleCharacter_NoExactMatch_NoPrefix() {
        let candidates = ["ABCD", "ABEF", "ACGH"]
        let result = StringMatcher.match(partial: "A", candidates: candidates)

        if case .noMatch = result {
            // Expected - single character without exact match returns noMatch
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test single character with different candidates
    func testSingleCharacter_DifferentLetter() {
        let candidates = ["A123", "B456", "C789"]
        let result = StringMatcher.match(partial: "B", candidates: candidates)

        if case .noMatch = result {
            // Expected - "B" doesn't exactly match any candidate
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    // MARK: - Prefix Match Tests (2+ Characters)

    /// Test single valid prefix match with UUID-like ID (2+ chars)
    func testPrefixMatch_UUID_TwoChars() {
        let candidates = ["550e8400-e29b-41d4-a716", "661f9511-f3ac-52e5-b827"]
        let result = StringMatcher.match(partial: "55", candidates: candidates)

        if case .singleMatch(let matched) = result {
            XCTAssertEqual(matched, "550e8400-e29b-41d4-a716")
        } else {
            XCTFail("Expected singleMatch but got \(result)")
        }
    }

    /// Test single valid prefix match with longer prefix
    func testPrefixMatch_UUID_LongerPrefix() {
        let candidates = ["550e8400-e29b-41d4-a716", "661f9511-f3ac-52e5-b827"]
        let result = StringMatcher.match(partial: "550e84", candidates: candidates)

        if case .singleMatch(let matched) = result {
            XCTAssertEqual(matched, "550e8400-e29b-41d4-a716")
        } else {
            XCTFail("Expected singleMatch but got \(result)")
        }
    }

    /// Test single valid prefix match with short alphanumeric ID
    func testPrefixMatch_ShortID() {
        let candidates = ["a1b2c3", "d4e5f6", "g7h8i9"]
        let result = StringMatcher.match(partial: "a1", candidates: candidates)

        if case .singleMatch(let matched) = result {
            XCTAssertEqual(matched, "a1b2c3")
        } else {
            XCTFail("Expected singleMatch but got \(result)")
        }
    }

    /// Test single valid prefix match with custom format ID
    func testPrefixMatch_CustomFormat() {
        let candidates = ["ABCD-1234-5678", "BCDE-2345-6789", "CDEF-3456-7890"]
        let result = StringMatcher.match(partial: "AB", candidates: candidates)

        if case .singleMatch(let matched) = result {
            XCTAssertEqual(matched, "ABCD-1234-5678")
        } else {
            XCTFail("Expected singleMatch but got \(result)")
        }
    }

    /// Test prefix match up to a dash separator
    func testPrefixMatch_UpToDash() {
        let candidates = ["ABCD-1234-5678", "BCDE-2345-6789"]
        let result = StringMatcher.match(partial: "ABCD", candidates: candidates)

        if case .singleMatch(let matched) = result {
            XCTAssertEqual(matched, "ABCD-1234-5678")
        } else {
            XCTFail("Expected singleMatch but got \(result)")
        }
    }

    // MARK: - Multiple Prefix Matches (Ambiguous)

    /// Test ambiguous match with two candidates
    func testMultipleMatches_TwoCandidates() {
        let candidates = ["ABCD-1234", "ABEF-5678"]
        let result = StringMatcher.match(partial: "AB", candidates: candidates)

        if case .multipleMatches(let matches) = result {
            XCTAssertEqual(Set(matches), Set(["ABCD-1234", "ABEF-5678"]))
        } else {
            XCTFail("Expected multipleMatches but got \(result)")
        }
    }

    /// Test ambiguous match with multiple candidates (3+)
    func testMultipleMatches_ThreeCandidates() {
        let candidates = ["AA-123", "AA-456", "AA-789", "BB-000"]
        let result = StringMatcher.match(partial: "AA", candidates: candidates)

        if case .multipleMatches(let matches) = result {
            XCTAssertEqual(Set(matches), Set(["AA-123", "AA-456", "AA-789"]))
        } else {
            XCTFail("Expected multipleMatches but got \(result)")
        }
    }

    /// Test that longer prefix can resolve ambiguity
    func testMultipleMatches_ResolveWithLongerPrefix() {
        let candidates = ["ABCD-1234", "ABEF-5678"]

        // First verify "AB" is ambiguous
        let ambiguousResult = StringMatcher.match(partial: "AB", candidates: candidates)
        if case .multipleMatches = ambiguousResult {
            // Expected
        } else {
            XCTFail("Expected AB to be ambiguous")
        }

        // Then verify "ABCD" resolves to single match
        let resolvedResult = StringMatcher.match(partial: "ABCD", candidates: candidates)
        if case .singleMatch(let matched) = resolvedResult {
            XCTAssertEqual(matched, "ABCD-1234")
        } else {
            XCTFail("Expected singleMatch but got \(resolvedResult)")
        }
    }

    // MARK: - No Substring Match Tests

    /// Test that substring in middle does not match
    func testNoSubstringMatch_Middle() {
        let candidates = ["XXABCD", "YYABEF", "ZZABGH"]
        let result = StringMatcher.match(partial: "AB", candidates: candidates)

        if case .noMatch = result {
            // Expected - "AB" is not a prefix of any candidate
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test that substring at end does not match
    func testNoSubstringMatch_End() {
        let candidates = ["1234-ABCD", "5678-ABEF", "9012-ABGH"]
        let result = StringMatcher.match(partial: "AB", candidates: candidates)

        if case .noMatch = result {
            // Expected - "AB" is not a prefix of any candidate
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test the specific example from requirements: "A" should NOT match "BBBA-123123..."
    /// This tests both substring matching (fails) AND single-char rule (fails)
    func testNoSubstringMatch_RequirementExample() {
        let candidates = ["BBBA-123123-456456"]
        let result = StringMatcher.match(partial: "A", candidates: candidates)

        if case .noMatch = result {
            // Expected - "A" is not a prefix of "BBBA-123123-456456"
            // Also, single char "A" doesn't exactly match
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    // MARK: - Case Sensitivity Tests

    /// Test that matching is case-sensitive (lowercase vs uppercase)
    func testCaseSensitivity_LowercaseVsUppercase() {
        let candidates = ["ABCD-1234", "abcd-5678"]
        let result = StringMatcher.match(partial: "ab", candidates: candidates)

        if case .singleMatch(let matched) = result {
            XCTAssertEqual(matched, "abcd-5678")
        } else {
            XCTFail("Expected singleMatch('abcd-5678') but got \(result)")
        }
    }

    /// Test that wrong case doesn't match
    func testCaseSensitivity_WrongCase() {
        let candidates = ["ABCD-1234", "BCDE-5678"]
        let result = StringMatcher.match(partial: "ab", candidates: candidates)

        if case .noMatch = result {
            // Expected - "ab" doesn't match "ABCD-1234" (case sensitive)
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test mixed case matching
    func testCaseSensitivity_MixedCase() {
        let candidates = ["AbCd-1234", "aBcD-5678", "ABCD-9999"]
        let result = StringMatcher.match(partial: "AbC", candidates: candidates)

        if case .singleMatch(let matched) = result {
            XCTAssertEqual(matched, "AbCd-1234")
        } else {
            XCTFail("Expected singleMatch but got \(result)")
        }
    }

    // MARK: - Backward Compatibility Tests

    /// Test full ID match (backward compatibility)
    func testBackwardCompatibility_FullID() {
        let candidates = ["550e8400-e29b-41d4-a716-446655440000", "661f9511-f3ac-52e5-b827-557766551111"]
        let fullID = "550e8400-e29b-41d4-a716-446655440000"
        let result = StringMatcher.match(partial: fullID, candidates: candidates)

        if case .exactMatch(let matched) = result {
            XCTAssertEqual(matched, fullID)
        } else {
            XCTFail("Expected exactMatch but got \(result)")
        }
    }

    /// Test that full IDs still work even with partial matches available
    func testBackwardCompatibility_FullIDWithPartialMatches() {
        let candidates = ["ABCD-1234-5678", "ABCD-1234-9999"]
        let fullID = "ABCD-1234-5678"
        let result = StringMatcher.match(partial: fullID, candidates: candidates)

        if case .exactMatch(let matched) = result {
            XCTAssertEqual(matched, fullID)
        } else {
            XCTFail("Expected exactMatch but got \(result)")
        }
    }

    // MARK: - Edge Cases

    /// Test empty partial string should return noMatch
    func testEdgeCase_EmptyPartialString() {
        let candidates = ["ABCD-1234", "BCDE-5678"]
        let result = StringMatcher.match(partial: "", candidates: candidates)

        if case .noMatch = result {
            // Expected - empty string should always return noMatch
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test empty candidates list
    func testEdgeCase_EmptyCandidatesList() {
        let candidates: [String] = []
        let result = StringMatcher.match(partial: "ABC", candidates: candidates)

        if case .noMatch = result {
            // Expected
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test single candidate that doesn't match
    func testEdgeCase_SingleCandidateNoMatch() {
        let candidates = ["ABCD-1234"]
        let result = StringMatcher.match(partial: "XYZ", candidates: candidates)

        if case .noMatch = result {
            // Expected
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test whitespace in partial string (should not match)
    func testEdgeCase_WhitespaceInPartial() {
        let candidates = ["ABCD-1234", "BCDE-5678"]
        let result = StringMatcher.match(partial: "AB ", candidates: candidates)

        if case .noMatch = result {
            // Expected - "AB " (with space) doesn't match "ABCD-1234"
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }

    /// Test very long prefix (longer than all candidates)
    func testEdgeCase_VeryLongPrefix() {
        let candidates = ["ABC", "DEF"]
        let result = StringMatcher.match(partial: "ABCDEFGHIJKLMNOP", candidates: candidates)

        if case .noMatch = result {
            // Expected
        } else {
            XCTFail("Expected noMatch but got \(result)")
        }
    }
}
