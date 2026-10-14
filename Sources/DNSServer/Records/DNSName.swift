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

/// A DNS name encoded as a sequence of labels.
///
/// DNS names are encoded as: `[length][label][length][label]...[0]`
/// For example, "example.com" becomes: `[7]example[3]com[0]`
public struct DNSName: Sendable, Hashable, CustomStringConvertible {
    /// The labels that make up this name (e.g., ["example", "com"]).
    public private(set) var labels: [String]

    /// Creates a DNS name representing the root (empty label list).
    public init() {
        self.labels = []
    }

    /// Creates a validated DNS name from an array of labels.
    ///
    /// Validates structural RFC 1035 constraints only: no empty labels, each label ≤ 63
    /// bytes, total wire length ≤ 255 bytes. Does not enforce hostname character rules.
    /// Labels are lowercased to normalize for case-insensitive DNS comparison.
    ///
    /// - Throws: `DNSBindError.invalidName` if any label is empty, exceeds 63 bytes,
    ///   or if the total wire representation exceeds 255 bytes.
    public init(labels: [String]) throws {
        for label in labels {
            guard !label.isEmpty else {
                throw DNSBindError.invalidName("empty label")
            }
            guard label.utf8.count <= 63 else {
                throw DNSBindError.invalidName("label too long: \"\(label)\"")
            }
        }
        let wireLength = labels.reduce(1) { $0 + 1 + $1.utf8.count }
        guard wireLength <= 255 else {
            throw DNSBindError.invalidName("name too long")
        }
        self.labels = labels.map { $0.lowercased() }
    }

    /// Creates a validated DNS name from a dot-separated hostname string
    /// (e.g., `"example.com."` or `"example.com"`).
    ///
    /// A trailing dot is accepted but not required.
    /// An empty string produces the root name without error.
    ///
    /// Labels must start and end with a letter or digit (LDH hostname rule).
    /// Use `init(labels:)` directly when working with wire-decoded names that
    /// may contain non-hostname labels (e.g. service-discovery labels like `"_dns"`).
    ///
    /// - Throws: `DNSBindError.invalidName` if any label violates the character rules,
    ///   or if structural limits are exceeded (see `init(labels:)`).
    public init(_ hostname: String) throws {
        let normalized = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        guard !normalized.isEmpty else {
            self.init()
            return
        }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }
        let hostnameRegex = /[a-zA-Z0-9](?:[a-zA-Z0-9\-_]*[a-zA-Z0-9])?/
        for part in parts {
            guard part.wholeMatch(of: hostnameRegex) != nil else {
                throw DNSBindError.invalidName(
                    "label must start and end with a letter or digit: \"\(part)\""
                )
            }
        }
        try self.init(labels: parts)
    }

    /// The wire format size of this name in bytes.
    public var size: Int {
        // Each label: 1 byte length + label bytes, plus 1 byte for null terminator
        labels.reduce(1) { $0 + 1 + $1.utf8.count }
    }

    /// The fully-qualified domain name with trailing dot.
    public var description: String {
        labels.joined(separator: ".") + "."
    }

    /// The partially-qualified domain name, which is the FQDN less the trailing dot.
    public var pqdn: String {
        labels.joined(separator: ".")
    }

    /// Serialize this name into the buffer at the given offset.
    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        var offset = offset

        for label in labels {
            let bytes = Array(label.utf8)
            guard bytes.count <= 63 else {
                throw DNSBindError.marshalFailure(type: "DNSName", field: "label")
            }

            guard let newOffset = buffer.copyIn(as: UInt8.self, value: UInt8(bytes.count), offset: offset) else {
                throw DNSBindError.marshalFailure(type: "DNSName", field: "label")
            }
            offset = newOffset

            guard let newOffset = buffer.copyIn(buffer: bytes, offset: offset) else {
                throw DNSBindError.marshalFailure(type: "DNSName", field: "label")
            }
            offset = newOffset
        }

        // Null terminator
        guard let newOffset = buffer.copyIn(as: UInt8.self, value: 0, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "DNSName", field: "terminator")
        }

        guard newOffset == startOffset + size else {
            throw DNSBindError.unexpectedOffset(type: "DNSName", expected: startOffset + size, actual: newOffset)
        }
        return newOffset
    }

    /// Deserialize a name from the buffer at the given offset.
    ///
    /// - Parameters:
    ///   - buffer: The buffer to read from.
    ///   - offset: The offset to start reading.
    ///   - messageStart: The start of the DNS message (for compression pointer resolution).
    /// - Returns: The new offset after reading.
    public mutating func bindBuffer(
        _ buffer: inout [UInt8],
        offset: Int,
        messageStart: Int = 0
    ) throws -> Int {
        var offset = offset
        var collectedLabels: [String] = []
        var jumped = false
        var returnOffset = offset
        var pointerHops = 0

        while true {
            guard offset < buffer.count else {
                throw DNSBindError.unmarshalFailure(type: "DNSName", field: "name")
            }

            let length = buffer[offset]

            // Check for compression pointer (top 2 bits set)
            if (length & 0xC0) == 0xC0 {
                guard offset + 1 < buffer.count else {
                    throw DNSBindError.unmarshalFailure(type: "DNSName", field: "pointer")
                }

                pointerHops += 1
                guard pointerHops <= 10 else {
                    throw DNSBindError.unmarshalFailure(type: "DNSName", field: "pointer")
                }

                if !jumped {
                    returnOffset = offset + 2
                }

                // Calculate pointer offset from message start
                let pointer = Int(length & 0x3F) << 8 | Int(buffer[offset + 1])
                let pointerTarget = messageStart + pointer
                guard pointerTarget >= 0 && pointerTarget < offset && pointerTarget < buffer.count else {
                    throw DNSBindError.unmarshalFailure(type: "DNSName", field: "pointer")
                }
                offset = pointerTarget
                jumped = true
                continue
            }

            offset += 1

            // Null terminator - end of name
            if length == 0 {
                break
            }

            guard offset + Int(length) <= buffer.count else {
                throw DNSBindError.unmarshalFailure(type: "DNSName", field: "label")
            }

            let labelBytes = Array(buffer[offset..<offset + Int(length)])
            guard let label = String(bytes: labelBytes, encoding: .utf8) else {
                throw DNSBindError.unmarshalFailure(type: "DNSName", field: "label")
            }

            collectedLabels.append(label)
            offset += Int(length)
        }

        self = try DNSName(labels: collectedLabels)
        return jumped ? returnOffset : offset
    }
}
