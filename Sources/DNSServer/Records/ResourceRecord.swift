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

/// Protocol for DNS resource records.
public protocol ResourceRecord: Sendable {
    /// The domain name this record applies to.
    var name: String { get }

    /// The record type.
    var type: ResourceRecordType { get }

    /// The record class.
    var recordClass: ResourceRecordClass { get }

    /// Time to live in seconds.
    var ttl: UInt32 { get }

    /// Serialize this record into the buffer.
    func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int
}

/// A host record (A or AAAA) containing an IP address.
public struct HostRecord<T: IPAddressProtocol>: ResourceRecord {
    public let name: String
    public let type: ResourceRecordType
    public let recordClass: ResourceRecordClass
    public let ttl: UInt32
    public let ip: T

    public init(
        name: String,
        ttl: UInt32 = 300,
        ip: T,
        recordClass: ResourceRecordClass = .internet
    ) {
        self.name = name
        self.type = T.recordType
        self.recordClass = recordClass
        self.ttl = ttl
        self.ip = ip
    }

    public func appendBuffer(_ buffer: inout [UInt8], offset: Int) throws -> Int {
        var offset = offset

        // Write name
        let dnsName = DNSName(name)
        offset = try dnsName.appendBuffer(&buffer, offset: offset)

        // Write type (big-endian)
        guard let newOffset = buffer.copyIn(as: UInt16.self, value: type.rawValue.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "HostRecord", field: "type")
        }
        offset = newOffset

        // Write class (big-endian)
        guard let newOffset = buffer.copyIn(as: UInt16.self, value: recordClass.rawValue.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "HostRecord", field: "class")
        }
        offset = newOffset

        // Write TTL (big-endian)
        guard let newOffset = buffer.copyIn(as: UInt32.self, value: ttl.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "HostRecord", field: "ttl")
        }
        offset = newOffset

        // Write rdlength (big-endian)
        let rdlength = UInt16(T.size)
        guard let newOffset = buffer.copyIn(as: UInt16.self, value: rdlength.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "HostRecord", field: "rdlength")
        }
        offset = newOffset

        // Write IP address bytes
        guard let newOffset = buffer.copyIn(buffer: ip.bytes, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "HostRecord", field: "rdata")
        }

        return newOffset
    }
}
