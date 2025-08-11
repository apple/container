//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

/// A filesystem path that preserves exact byte sequences, including non-UTF8 paths.
///
/// This type is designed to handle paths from any filesystem, including Linux paths
/// that may contain non-UTF8 byte sequences. It stores paths as raw bytes internally
/// but provides convenient String access when the bytes are valid UTF-8.
///
/// Use cases:
/// - Processing Linux filesystem paths from macOS
/// - Preserving exact path bytes for deterministic hashing (DiffKey)
/// - Round-trip preservation of paths through tar archives
/// - Cross-platform path handling without encoding loss
public struct BinaryPath: Sendable, Hashable, Codable {
    /// The raw bytes of the path, including any non-UTF8 sequences
    private let bytes: Data

    // MARK: - Initialization

    /// Initialize from a Swift String (always valid UTF-8)
    public init(string: String) {
        self.bytes = Data(string.utf8)
    }

    /// Initialize from raw bytes (may contain non-UTF8 sequences)
    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Initialize from a C string pointer (null-terminated)
    public init(cString: UnsafePointer<CChar>) {
        let length = strlen(cString)
        self.bytes = Data(bytes: cString, count: length)
    }

    /// Initialize from a filesystem URL, capturing the exact bytes
    public init(url: URL) {
        self.bytes = url.withUnsafeFileSystemRepresentation { ptr in
            guard let ptr = ptr else {
                // Fallback to String representation if pointer is nil
                return Data(url.path.utf8)
            }
            let length = strlen(ptr)
            return Data(bytes: ptr, count: length)
        }
    }

    // MARK: - Accessors

    /// Returns the path as a String if it contains valid UTF-8, nil otherwise
    public var stringValue: String? {
        String(data: bytes, encoding: .utf8)
    }

    /// Returns the path as a String, replacing invalid UTF-8 sequences with replacement character
    public var requireString: String {
        // Try UTF-8 first
        if let str = String(data: bytes, encoding: .utf8) {
            return str
        }

        // Fallback: decode with replacement character for invalid sequences
        var str = ""
        var iterator = bytes.makeIterator()
        var buffer: [UInt8] = []

        while let byte = iterator.next() {
            buffer.append(byte)

            // Try to decode accumulated bytes
            if let decoded = String(bytes: buffer, encoding: .utf8) {
                str.append(decoded)
                buffer.removeAll()
            } else if buffer.count >= 4 {
                // Invalid UTF-8 sequence, use replacement character
                str.append("\u{FFFD}")  // Unicode replacement character
                buffer.removeAll()
            }
        }

        // Handle any remaining bytes
        if !buffer.isEmpty {
            str.append("\u{FFFD}")
        }

        return str.isEmpty ? "/" : str
    }

    /// The raw bytes of the path
    public var rawBytes: Data {
        bytes
    }

    /// Returns true if the path contains valid UTF-8
    public var isValidUTF8: Bool {
        stringValue != nil
    }

    /// Returns true if this represents an empty path
    public var isEmpty: Bool {
        bytes.isEmpty
    }

    // MARK: - Path Operations

    /// Appends a path component
    public func appending(_ component: BinaryPath) -> BinaryPath {
        guard !component.isEmpty else { return self }
        guard !self.isEmpty else { return component }

        var result = bytes

        // Add separator if needed
        if !result.isEmpty && result.last != UInt8(ascii: "/") {
            result.append(UInt8(ascii: "/"))
        }

        // Skip leading separator in component if present
        let componentBytes = component.bytes
        if componentBytes.first == UInt8(ascii: "/") {
            result.append(componentBytes.dropFirst())
        } else {
            result.append(componentBytes)
        }

        return BinaryPath(bytes: result)
    }

    /// Removes the last path component
    public func deletingLastPathComponent() -> BinaryPath {
        guard !bytes.isEmpty else { return self }

        // Find last separator
        if let lastSlash = bytes.lastIndex(of: UInt8(ascii: "/")) {
            // Keep the slash if it's the root
            if lastSlash == bytes.startIndex {
                return BinaryPath(bytes: Data([UInt8(ascii: "/")]))
            }
            return BinaryPath(bytes: bytes.prefix(upTo: lastSlash))
        }

        // No separator found, return empty
        return BinaryPath(bytes: Data())
    }

    /// Returns the last path component
    public var lastPathComponent: BinaryPath {
        guard !bytes.isEmpty else { return self }

        // Find last separator
        if let lastSlash = bytes.lastIndex(of: UInt8(ascii: "/")) {
            let afterSlash = bytes.index(after: lastSlash)
            if afterSlash < bytes.endIndex {
                return BinaryPath(bytes: bytes.suffix(from: afterSlash))
            }
            return BinaryPath(bytes: Data())
        }

        // No separator, entire path is the component
        return self
    }

    /// Returns path components split by separator
    public var components: [BinaryPath] {
        guard !bytes.isEmpty else { return [] }

        var components: [BinaryPath] = []
        var current = Data()

        for byte in bytes {
            if byte == UInt8(ascii: "/") {
                if !current.isEmpty {
                    components.append(BinaryPath(bytes: current))
                    current = Data()
                }
            } else {
                current.append(byte)
            }
        }

        if !current.isEmpty {
            components.append(BinaryPath(bytes: current))
        }

        return components
    }

    // MARK: - Interop

    /// Execute a closure with a C string representation of the path
    public func withCString<T>(_ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
        // Ensure null termination
        var nullTerminated = bytes
        if nullTerminated.isEmpty || nullTerminated.last != 0 {
            nullTerminated.append(0)
        }

        return try nullTerminated.withUnsafeBytes { buffer in
            let cString = buffer.bindMemory(to: CChar.self).baseAddress!
            return try body(cString)
        }
    }

    /// Create a URL if the path is valid UTF-8
    public var url: URL? {
        guard let str = stringValue else { return nil }
        return URL(fileURLWithPath: str)
    }

    // MARK: - Comparison

    /// Lexicographic comparison of raw bytes (for deterministic sorting)
    public static func < (lhs: BinaryPath, rhs: BinaryPath) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // First try to decode as String (common case)
        if let string = try? container.decode(String.self) {
            self.bytes = Data(string.utf8)
            return
        }

        // Fallback to base64-encoded Data for non-UTF8 paths
        let encodedData = try container.decode(Data.self)
        self.bytes = encodedData
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        // Encode as String if valid UTF-8
        if let string = stringValue {
            try container.encode(string)
        } else {
            // Encode as base64 Data for non-UTF8 paths
            try container.encode(bytes)
        }
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        if let str = stringValue {
            return str
        }
        return "<BinaryPath: \(bytes.count) bytes, non-UTF8>"
    }
}

// MARK: - Convenience Extensions

extension BinaryPath: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(string: value)
    }
}

extension BinaryPath {
    /// Creates a relative path from base to self
    public func relativePath(from base: BinaryPath) -> BinaryPath? {
        let baseBytes = base.bytes
        let selfBytes = self.bytes

        // Ensure base ends with separator for proper prefix matching
        var baseWithSep = baseBytes
        if !baseWithSep.isEmpty && baseWithSep.last != UInt8(ascii: "/") {
            baseWithSep.append(UInt8(ascii: "/"))
        }

        // Check if self starts with base
        if selfBytes.starts(with: baseWithSep) {
            return BinaryPath(bytes: selfBytes.dropFirst(baseWithSep.count))
        } else if selfBytes == baseBytes {
            return BinaryPath(bytes: Data())
        }

        return nil
    }

    /// Checks if this path has the given prefix
    public func hasPrefix(_ prefix: BinaryPath) -> Bool {
        bytes.starts(with: prefix.bytes)
    }

    /// Checks if this path has the given suffix
    public func hasSuffix(_ suffix: BinaryPath) -> Bool {
        bytes.hasSuffix(suffix.bytes)
    }
}

// MARK: - Data Extension

extension Data {
    fileprivate func hasSuffix(_ suffix: Data) -> Bool {
        guard count >= suffix.count else { return false }
        return self.suffix(suffix.count) == suffix
    }
}
