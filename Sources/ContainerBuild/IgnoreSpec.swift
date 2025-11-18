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

        let globber = Globber(URL(fileURLWithPath: "/"))

        for pattern in patterns {
            // According to Docker's .dockerignore spec, patterns match at any depth
            // unless they start with / (which means root only)

            let pathToMatch = isDirectory ? relPath + "/" : relPath

            // Get the base name (last component) of the path for simple pattern matching
            let pathComponents = relPath.split(separator: "/")
            let baseName = String(pathComponents.last ?? "")
            let baseNameToMatch = isDirectory ? baseName + "/" : baseName

            // Try exact match first (handles absolute patterns like /node_modules)
            if try globber.glob(pathToMatch, pattern) {
                return true
            }

            // Also try without trailing slash for directories
            if isDirectory {
                let matchesNoSlash = try globber.glob(relPath, pattern)
                if matchesNoSlash {
                    return true
                }
            }

            // For patterns without leading /, they should match at any depth
            // Try matching against just the basename
            if !pattern.hasPrefix("/") {
                let baseMatches = try globber.glob(baseNameToMatch, pattern)
                if baseMatches {
                    return true
                }
                if isDirectory {
                    let baseMatchesNoSlash = try globber.glob(baseName, pattern)
                    if baseMatchesNoSlash {
                        return true
                    }
                }
            }
        }

        return false
    }
}
