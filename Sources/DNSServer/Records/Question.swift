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

/// A DNS question (query).
///
/// All domain names in a `Question` are canonical DNS names — fully-qualified
/// with a trailing dot (e.g. `"example.com."`). This invariant is not enforced
/// automatically; callers are responsible for supplying canonical names.
public struct Question: Sendable, CustomStringConvertible {
    /// The fully-qualified domain name being queried, with a trailing dot (e.g. `"example.com."`).
    public var name: String

    /// The record type being requested.
    public var type: ResourceRecordType

    /// The record class (usually .internet).
    public var recordClass: ResourceRecordClass

    /// Creates a DNS question.
    ///
    /// - Parameter name: The fully-qualified domain name to query, with a trailing dot
    ///   (e.g. `"example.com."`). Supplying a name without a trailing dot will produce
    ///   lookup mismatches against canonically-stored records.
    /// - Parameter type: The record type being requested.
    /// - Parameter recordClass: The record class (usually `.internet`).
    public init(
        name: String,
        type: ResourceRecordType = .host,
        recordClass: ResourceRecordClass = .internet
    ) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
    }

    public var description: String {
        "\(name) \(type) \(recordClass)"
    }

    /// Serialize this question into the buffer.
    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        let startOffset = offset
        var offset = offset

        // Write name
        let normalized = name.hasSuffix(".") ? String(name.dropLast()) : name
        let dnsName = try DNSName(labels: normalized.isEmpty ? [] : normalized.split(separator: ".", omittingEmptySubsequences: false).map(String.init))
        offset = try dnsName.appendBuffer(&buffer, offset: offset)

        // Write type (big-endian)
        guard let newOffset = buffer.copyIn(as: UInt16.self, value: type.rawValue.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Question", field: "type")
        }
        offset = newOffset

        // Write class (big-endian)
        guard let newOffset = buffer.copyIn(as: UInt16.self, value: recordClass.rawValue.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Question", field: "class")
        }

        let expectedOffset = startOffset + dnsName.size + 4
        guard newOffset == expectedOffset else {
            throw DNSBindError.unexpectedOffset(type: "Question", expected: expectedOffset, actual: newOffset)
        }
        return newOffset
    }

    /// Deserialize a question from the buffer.
    public mutating func bindBuffer(_ buffer: inout [UInt8], offset: Int, messageStart: Int = 0) throws -> Int {
        var offset = offset

        // Read name
        var dnsName = DNSName()
        offset = try dnsName.bindBuffer(&buffer, offset: offset, messageStart: messageStart)
        self.name = dnsName.description

        // Read type (big-endian)
        guard let (newOffset, rawType) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Question", field: "type")
        }
        guard let qtype = ResourceRecordType(rawValue: UInt16(bigEndian: rawType)) else {
            throw DNSBindError.unsupportedValue(type: "Question", field: "type")
        }
        self.type = qtype
        offset = newOffset

        // Read class (big-endian)
        guard let (newOffset, rawClass) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Question", field: "class")
        }
        guard let qclass = ResourceRecordClass(rawValue: UInt16(bigEndian: rawClass)) else {
            throw DNSBindError.unsupportedValue(type: "Question", field: "class")
        }
        self.recordClass = qclass

        return newOffset
    }
}
