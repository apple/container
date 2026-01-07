//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

public class Globber {
    let input: URL
    var results: Set<URL> = .init()

    public init(_ input: URL) {
        self.input = input
    }

    public func match(_ pattern: String) throws {
        let adjustedPattern =
            pattern
            .replacingOccurrences(of: #"^\./(?=.)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "^\\.[/]?$", with: "*", options: .regularExpression)
            .replacingOccurrences(of: "\\*{2,}[/]", with: "*/**/", options: .regularExpression)
            .replacingOccurrences(of: "[/]\\*{2,}([^/])", with: "/**/*$1", options: .regularExpression)
            .replacingOccurrences(of: "^\\*{2,}([^/])", with: "**/*$1", options: .regularExpression)

        for child in input.children {
            try self.match(input: child, components: adjustedPattern.split(separator: "/").map(String.init))
        }
    }

    private func match(input: URL, components: [String]) throws {
        if components.isEmpty {
            var dir = input.standardizedFileURL

            while dir != self.input.standardizedFileURL {
                results.insert(dir)
                guard dir.pathComponents.count > 1 else { break }
                dir.deleteLastPathComponent()
            }
            return input.childrenRecursive.forEach { results.insert($0) }
        }

        let head = components.first ?? ""
        let tail = components.tail

        if head == "**" {
            var tail: [String] = tail
            while tail.first == "**" {
                tail = tail.tail
            }
            try self.match(input: input, components: tail)
            for child in input.children {
                try self.match(input: child, components: components)
            }
            return
        }

        if try glob(input.lastPathComponent, head) {
            try self.match(input: input, components: tail)

            for child in input.children where try glob(child.lastPathComponent, tail.first ?? "") {
                try self.match(input: child, components: tail)
            }
            return
        }
    }

    func glob(_ input: String, _ pattern: String) throws -> Bool {
        let regexPattern =
            "^"
            + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
            .replacingOccurrences(of: "[\\^", with: "[^")
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]") + "$"

        // validate the regex pattern created
        let _ = try Regex(regexPattern)
        return input.range(of: regexPattern, options: .regularExpression) != nil
    }
}

extension URL {
    var children: [URL] {

        (try? FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil))
            ?? []
    }

    var childrenRecursive: [URL] {
        var results: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: self, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
            while let child = enumerator.nextObject() as? URL {
                results.append(child)
            }
        }
        return [self] + results
    }
}

extension [String] {
    var tail: [String] {
        if self.count <= 1 {
            return []
        }
        return Array(self.dropFirst())
    }
}
