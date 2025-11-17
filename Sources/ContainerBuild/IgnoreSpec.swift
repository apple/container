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

/// A type that handles .dockerignore pattern matching
struct IgnoreSpec {
    private let patterns: [String]

    /// Initialize an IgnoreSpec from .dockerignore file data
    /// - Parameter data: The contents of a .dockerignore file
    init(_ data: Data) {
        guard let contents = String(data: data, encoding: .utf8) else {
            self.patterns = []
            return
        }

        self.patterns =
            contents
            .split(separator: "\n")
            .map { line in line.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !line.hasPrefix("#") }
            .map { String($0) }
    }

    /// Check if a file path should be ignored based on .dockerignore patterns
    /// - Parameters:
    ///   - relPath: The relative path to check
    ///   - isDirectory: Whether the path is a directory
    /// - Returns: true if the path should be ignored, false otherwise
    func shouldIgnore(relPath: String, isDirectory: Bool) throws -> Bool {
        guard !patterns.isEmpty else {
            return false
        }

        for pattern in patterns {
            if try matchesPattern(path: relPath, pattern: pattern, isDirectory: isDirectory) {
                return true
            }
        }

        return false
    }

    /// Match a path against a dockerignore pattern
    /// - Parameters:
    ///   - path: The path to match
    ///   - pattern: The dockerignore pattern
    ///   - isDirectory: Whether the path is a directory
    /// - Returns: true if the path matches the pattern
    private func matchesPattern(path: String, pattern: String, isDirectory: Bool) throws -> Bool {
        var pattern = pattern

        // Handle trailing slash on pattern (means directories only)
        let dirOnly = pattern.hasSuffix("/")
        if dirOnly {
            pattern = String(pattern.dropLast())
            if !isDirectory {
                return false
            }
        }

        // Handle root-only patterns (starting with /)
        let rootOnly = pattern.hasPrefix("/")
        if rootOnly {
            pattern = String(pattern.dropFirst())
        }

        // Convert pattern to regex, handling ** specially
        let regex = try patternToRegex(pattern: pattern, rootOnly: rootOnly)

        // Try matching the path (and with trailing slash for directories)
        if path.range(of: regex, options: .regularExpression) != nil {
            return true
        }

        if isDirectory {
            let pathWithSlash = path + "/"
            if pathWithSlash.range(of: regex, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    /// Convert a dockerignore pattern to a regex pattern
    /// - Parameters:
    ///   - pattern: The dockerignore pattern
    ///   - rootOnly: Whether the pattern should only match at root
    /// - Returns: A regex pattern string
    private func patternToRegex(pattern: String, rootOnly: Bool) throws -> String {
        var result = ""

        // If not root-only, pattern can match at any depth
        if !rootOnly && !pattern.hasPrefix("**/") {
            // Pattern matches at any depth (like **/pattern)
            result = "(?:^|.*/)"
        } else {
            result = "^"
        }

        // Process the pattern
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let char = pattern[i]

            // Handle **
            if char == "*" && pattern.index(after: i) < pattern.endIndex && pattern[pattern.index(after: i)] == "*" {
                // Check if it's **/ or just **
                let afterStar = pattern.index(i, offsetBy: 2)
                if afterStar < pattern.endIndex && pattern[afterStar] == "/" {
                    // **/ matches zero or more path segments
                    result += "(?:.*/)?"
                    i = pattern.index(after: afterStar)
                    continue
                } else if afterStar == pattern.endIndex {
                    // ** at end matches anything
                    result += ".*"
                    i = afterStar
                    continue
                }
            }

            // Handle single *
            if char == "*" {
                result += "[^/]*"
                i = pattern.index(after: i)
                continue
            }

            // Handle ?
            if char == "?" {
                result += "[^/]"
                i = pattern.index(after: i)
                continue
            }

            // Handle character classes [...]
            if char == "[" {
                var j = pattern.index(after: i)
                while j < pattern.endIndex && pattern[j] != "]" {
                    j = pattern.index(after: j)
                }
                if j < pattern.endIndex {
                    let charClass = String(pattern[i...j])
                    result += charClass
                    i = pattern.index(after: j)
                    continue
                }
            }

            // Escape special regex characters
            let specialChars = "\\^$.+(){}|"
            if specialChars.contains(char) {
                result += "\\"
            }
            result += String(char)
            i = pattern.index(after: i)
        }

        result += "$"
        return result
    }
}
