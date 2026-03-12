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
    public var labels: [String]

    /// Creates a DNS name from an array of labels.
    public init(labels: [String] = []) {
        self.labels = labels
    }

    /// Creates a DNS name from a dot-separated string (e.g., "example.com.").
    public init(_ string: String) {
        // Remove trailing dot if present, then split
        let normalized = string.hasSuffix(".") ? String(string.dropLast()) : string
        self.labels = normalized.isEmpty ? [] : normalized.split(separator: ".").map(String.init)
    }

    /// The wire format size of this name in bytes.
    public var size: Int {
        // Each label: 1 byte length + label bytes, plus 1 byte for null terminator
        labels.reduce(1) { $0 + 1 + $1.utf8.count }
    }

    /// The fully-qualified domain name with trailing dot.
    public var description: String {
        labels.isEmpty ? "." : labels.joined(separator: ".") + "."
    }

    /// Serialize this name into the buffer at the given offset.
    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        var offset = offset

        for label in labels {
            let bytes = Array(label.utf8)
            guard bytes.count <= 63 else {
                throw DNSBindError.marshalFailure(type: "DNSName", field: "label too long")
            }

            guard let newOffset = buffer.copyIn(as: UInt8.self, value: UInt8(bytes.count), offset: offset) else {
                throw DNSBindError.marshalFailure(type: "DNSName", field: "label length")
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
        labels = []
        var jumped = false
        var returnOffset = offset

        while true {
            guard offset < buffer.count else {
                throw DNSBindError.unmarshalFailure(type: "DNSName", field: "unexpected end")
            }

            let length = buffer[offset]

            // Check for compression pointer (top 2 bits set)
            if (length & 0xC0) == 0xC0 {
                guard offset + 1 < buffer.count else {
                    throw DNSBindError.unmarshalFailure(type: "DNSName", field: "compression pointer")
                }

                if !jumped {
                    returnOffset = offset + 2
                }

                // Calculate pointer offset from message start
                let pointer = Int(length & 0x3F) << 8 | Int(buffer[offset + 1])
                offset = messageStart + pointer
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
                throw DNSBindError.unmarshalFailure(type: "DNSName", field: "label encoding")
            }

            labels.append(label)
            offset += Int(length)
        }

        return jumped ? returnOffset : offset
    }
}
