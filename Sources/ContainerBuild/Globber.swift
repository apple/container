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

import ContainerizationOS
import Foundation
import SystemPackage

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

        for child in self.children(of: input) {
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
            return self.childrenRecursive(of: input).forEach { results.insert($0) }
        }

        let head = components.first ?? ""
        let tail = components.tail

        if head == "**" {
            var tail: [String] = tail
            while tail.first == "**" {
                tail = tail.tail
            }
            try self.match(input: input, components: tail)
            for child in self.children(of: input) {
                try self.match(input: child, components: components)
            }
            return
        }

        if try glob(input.lastPathComponent, head) {
            try self.match(input: input, components: tail)

            for child in self.children(of: input) where try glob(child.lastPathComponent, tail.first ?? "") {
                try self.match(input: child, components: tail)
            }
            return
        }
    }

    /// Returns the direct children of `url`, following `url` itself when it is
    /// a directory symlink whose fully-resolved target stays within the match
    /// root. A symlink that escapes the root is treated as having no children
    /// (same as a regular file) so pattern components after it never match —
    /// mirrors the containment check `BuildFSSync` applies before reading.
    ///
    /// Children are named by their resolved (physical) path, not by `url`, so
    /// that `walk(root:includePatterns:)`'s later filter — which is driven by
    /// `Archiver.compress`'s own physical directory walk — reliably finds a
    /// matching entry regardless of whether that walk itself follows `url`'s
    /// symlink. `url` is separately inserted into `results` so the symlink
    /// entry is still present in the tar for the builder to resolve the
    /// original path against.
    private func children(of url: URL) -> [URL] {
        // TODO: modifying object state and returning results is odd, rework
        guard let dir = self.resolvedDirectory(of: url) else { return [] }
        if url.isSymlink { self.results.insert(url) }
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            ?? []
    }

    /// Recursive form of ``children(of:)``, used once a full pattern (or `**`)
    /// has matched `url` and every descendant needs to be collected. Nested
    /// directory symlinks are resolved and boundary-checked the same way, one
    /// level at a time, via ``FileDescriptorOps/enumerate`` which never follows
    /// symlinks it encounters mid-traversal — only the top-level `url` passed
    /// in here gets the resolve-and-check treatment.
    private func childrenRecursive(of url: URL) -> [URL] {
        guard let dir = self.resolvedDirectory(of: url) else { return [url] }
        if url.isSymlink { self.results.insert(url) }
        guard let fd = try? FileDescriptor.open(FilePath(dir.path), .readOnly, options: .directory) else {
            return [dir]
        }
        defer { try? fd.close() }
        var found: [URL] = [dir]
        try? FileDescriptorOps.enumerate(fd) { relPath, _, _ in
            found.append(dir.appendingPathComponent(relPath.string))
        }
        return found
    }

    /// Resolves `url` to the real directory whose contents should be listed in
    /// its place. Non-symlinks resolve to themselves. A directory symlink
    /// resolves to its target only if the fully-resolved target is still
    /// within `self.input` (the match root); otherwise `nil`, so callers treat
    /// it as a leaf rather than descending outside the context.
    private func resolvedDirectory(of url: URL) -> URL? {
        guard url.isSymlink else { return url }
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.isDirectory, self.input.parentOf(resolved) else { return nil }
        return resolved
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

extension [String] {
    var tail: [String] {
        if self.count <= 1 {
            return []
        }
        return Array(self.dropFirst())
    }
}
