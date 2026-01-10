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

/// Represents a path for the `container cp` command.
/// Can be either a container path (container:path) or a local filesystem path.
public enum CopyPath: Equatable, Sendable {
    /// A path inside a container, identified by container ID and path within the container.
    case container(id: String, path: String)
    /// A path on the local filesystem.
    case local(path: String)

    /// Parse a path string into a CopyPath.
    ///
    /// Path format:
    /// - `container:path` or `container:/path` → container path
    /// - `/path`, `./path`, `../path`, `path` → local path
    /// - `-` → stdin/stdout streaming (treated as local)
    ///
    /// Special handling:
    /// - Paths starting with `.` or `/` are always local (even with colons in filename)
    /// - Drive letters on Windows-style paths are not supported
    ///
    /// - Parameter input: The path string to parse
    /// - Returns: A CopyPath representing either a container or local path
    public static func parse(_ input: String) -> CopyPath {
        // Handle stdin/stdout streaming
        if input == "-" {
            return .local(path: "-")
        }

        // Paths starting with / or . are always local
        // This handles cases like ./file:with:colons or /path/to/file:name
        if input.hasPrefix("/") || input.hasPrefix("./") || input.hasPrefix("../") {
            return .local(path: input)
        }

        // Look for container:path pattern
        // The container ID is everything before the first colon
        if let colonIndex = input.firstIndex(of: ":") {
            let containerId = String(input[..<colonIndex])
            let pathStartIndex = input.index(after: colonIndex)
            let path = String(input[pathStartIndex...])

            // Validate container ID is not empty and looks reasonable
            // Container IDs should not be empty and should not look like paths
            if !containerId.isEmpty && !containerId.contains("/") {
                // Normalize the path - if empty, default to root
                let normalizedPath = path.isEmpty ? "/" : path
                return .container(id: containerId, path: normalizedPath)
            }
        }

        // Default to local path
        return .local(path: input)
    }

    /// Check if this path represents a container path.
    public var isContainer: Bool {
        if case .container = self {
            return true
        }
        return false
    }

    /// Check if this path represents a local path.
    public var isLocal: Bool {
        if case .local = self {
            return true
        }
        return false
    }

    /// Get the container ID if this is a container path.
    public var containerId: String? {
        if case .container(let id, _) = self {
            return id
        }
        return nil
    }

    /// Get the path component (works for both container and local paths).
    public var path: String {
        switch self {
        case .container(_, let path):
            return path
        case .local(let path):
            return path
        }
    }

    /// Check if the path ends with a directory indicator (trailing slash or /.).
    public var isDirectoryPath: Bool {
        let p = path
        return p.hasSuffix("/") || p.hasSuffix("/.")
    }

    /// Check if this represents a "copy contents only" path (ends with /.).
    public var copyContentsOnly: Bool {
        path.hasSuffix("/.")
    }

    /// Get the directory name (parent directory) of the path.
    public var dirname: String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path
    }

    /// Get the base name (last component) of the path.
    public var basename: String {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent
    }

    /// Get the path with any trailing /. removed.
    public var normalizedPath: String {
        var p = path
        if p.hasSuffix("/.") {
            p = String(p.dropLast(2))
        }
        if p.isEmpty {
            p = "/"
        }
        return p
    }
}
