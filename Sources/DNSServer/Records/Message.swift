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

/// A DNS message (query or response).
///
/// Wire format (RFC 1035):
/// ```
/// +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
/// |                      ID                       |
/// +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
/// |QR|   Opcode  |AA|TC|RD|RA|   Z    |   RCODE   |
/// +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
/// |                    QDCOUNT                    |
/// +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
/// |                    ANCOUNT                    |
/// +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
/// |                    NSCOUNT                    |
/// +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
/// |                    ARCOUNT                    |
/// +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
/// ```
public struct Message: Sendable {
    /// Header size in bytes.
    public static let headerSize = 12

    /// Transaction ID.
    public var id: UInt16

    /// Message type (query or response).
    public var type: MessageType

    /// Operation code.
    public var operationCode: OperationCode

    /// Authoritative answer flag.
    public var authoritativeAnswer: Bool

    /// Truncation flag.
    public var truncation: Bool

    /// Recursion desired flag.
    public var recursionDesired: Bool

    /// Recursion available flag.
    public var recursionAvailable: Bool

    /// Response code.
    public var returnCode: ReturnCode

    /// Questions in this message.
    public var questions: [Question]

    /// Answer resource records.
    public var answers: [ResourceRecord]

    /// Authority resource records.
    public var authorities: [ResourceRecord]

    /// Additional resource records.
    public var additional: [ResourceRecord]

    private var rawAnswerCount: UInt16?
    private var rawAuthorityCount: UInt16?
    private var rawAdditionalCount: UInt16?
    private var rawResourceRecords: Data?

    /// Creates a new DNS message.
    public init(
        id: UInt16 = 0,
        type: MessageType = .query,
        operationCode: OperationCode = .query,
        authoritativeAnswer: Bool = false,
        truncation: Bool = false,
        recursionDesired: Bool = false,
        recursionAvailable: Bool = false,
        returnCode: ReturnCode = .noError,
        questions: [Question] = [],
        answers: [ResourceRecord] = [],
        authorities: [ResourceRecord] = [],
        additional: [ResourceRecord] = []
    ) {
        self.id = id
        self.type = type
        self.operationCode = operationCode
        self.authoritativeAnswer = authoritativeAnswer
        self.truncation = truncation
        self.recursionDesired = recursionDesired
        self.recursionAvailable = recursionAvailable
        self.returnCode = returnCode
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additional = additional
        self.rawAnswerCount = nil
        self.rawAuthorityCount = nil
        self.rawAdditionalCount = nil
        self.rawResourceRecords = nil
    }

    /// Deserialize a DNS message from raw data.
    public init(deserialize data: Data) throws {
        var buffer = Array(data)
        var offset = 0

        // Read ID
        guard let (newOffset, rawId) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Message", field: "id")
        }
        self.id = UInt16(bigEndian: rawId)
        offset = newOffset

        // Read flags
        guard let (newOffset, rawFlags) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Message", field: "flags")
        }
        let flags = UInt16(bigEndian: rawFlags)
        offset = newOffset

        // Parse flags
        self.type = (flags & 0x8000) != 0 ? .response : .query
        guard let opCode = OperationCode(rawValue: UInt8((flags >> 11) & 0x0F)) else {
            throw DNSBindError.unsupportedValue(type: "Message", field: "opcode")
        }
        self.operationCode = opCode
        self.authoritativeAnswer = (flags & 0x0400) != 0
        self.truncation = (flags & 0x0200) != 0
        self.recursionDesired = (flags & 0x0100) != 0
        self.recursionAvailable = (flags & 0x0080) != 0
        guard let returnCode = ReturnCode(rawValue: UInt8(flags & 0x000F)) else {
            throw DNSBindError.unsupportedValue(type: "Message", field: "rcode")
        }
        self.returnCode = returnCode

        // Read counts
        guard let (newOffset, rawQdCount) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Message", field: "qdcount")
        }
        let qdCount = UInt16(bigEndian: rawQdCount)
        offset = newOffset

        guard let (newOffset, rawAnCount) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Message", field: "ancount")
        }
        let anCount = UInt16(bigEndian: rawAnCount)
        offset = newOffset

        guard let (newOffset, rawNsCount) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Message", field: "nscount")
        }
        let nsCount = UInt16(bigEndian: rawNsCount)
        offset = newOffset

        guard let (newOffset, rawArCount) = buffer.copyOut(as: UInt16.self, offset: offset) else {
            throw DNSBindError.unmarshalFailure(type: "Message", field: "arcount")
        }
        let arCount = UInt16(bigEndian: rawArCount)
        offset = newOffset

        // Read questions
        self.questions = []
        for _ in 0..<qdCount {
            var question = Question(name: "")
            offset = try question.bindBuffer(&buffer, offset: offset, messageStart: 0)
            self.questions.append(question)
        }

        // Resource-record parsing is intentionally minimal. Preserve the raw
        // section so forwarded DNS responses can be serialized without dropping
        // upstream answers.
        self.answers = []
        self.authorities = []
        self.additional = []
        self.rawAnswerCount = anCount
        self.rawAuthorityCount = nsCount
        self.rawAdditionalCount = arCount
        self.rawResourceRecords = offset < buffer.count ? Data(buffer[offset...]) : nil
    }

    /// Serialize this message to raw data.
    public func serialize() throws -> Data {
        // Calculate exact buffer size.
        var bufferSize = Self.headerSize
        for question in questions {
            // name + type + class
            let n = question.name.hasSuffix(".") ? String(question.name.dropLast()) : question.name
            bufferSize += (try DNSName(labels: n.isEmpty ? [] : n.split(separator: ".", omittingEmptySubsequences: false).map(String.init))).size + 4
        }
        for answer in answers {
            // name + type + class + ttl + rdlen + rdata
            let n = answer.name.hasSuffix(".") ? String(answer.name.dropLast()) : answer.name
            let rdataSize = answer.type == .host ? 4 : 16
            bufferSize += (try DNSName(labels: n.isEmpty ? [] : n.split(separator: ".", omittingEmptySubsequences: false).map(String.init))).size + 10 + rdataSize
        }
        if shouldSerializeRawResourceRecords, let rawResourceRecords {
            bufferSize += rawResourceRecords.count
        }

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var offset = 0

        // Write ID
        guard let newOffset = buffer.copyIn(as: UInt16.self, value: id.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Message", field: "id")
        }
        offset = newOffset

        // Build and write flags
        var flags: UInt16 = 0
        flags |= type == .response ? 0x8000 : 0
        flags |= UInt16(operationCode.rawValue) << 11
        flags |= authoritativeAnswer ? 0x0400 : 0
        flags |= truncation ? 0x0200 : 0
        flags |= recursionDesired ? 0x0100 : 0
        flags |= recursionAvailable ? 0x0080 : 0
        flags |= UInt16(returnCode.rawValue)

        guard let newOffset = buffer.copyIn(as: UInt16.self, value: flags.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Message", field: "flags")
        }
        offset = newOffset

        // Write counts
        guard questions.count <= UInt16.max else {
            throw DNSBindError.marshalFailure(type: "Message", field: "qdcount")
        }
        guard answers.count <= UInt16.max else {
            throw DNSBindError.marshalFailure(type: "Message", field: "ancount")
        }
        guard authorities.count <= UInt16.max else {
            throw DNSBindError.marshalFailure(type: "Message", field: "nscount")
        }
        guard additional.count <= UInt16.max else {
            throw DNSBindError.marshalFailure(type: "Message", field: "arcount")
        }

        guard let newOffset = buffer.copyIn(as: UInt16.self, value: UInt16(questions.count).bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Message", field: "qdcount")
        }
        offset = newOffset

        let answerCount = shouldSerializeRawResourceRecords ? (rawAnswerCount ?? 0) : UInt16(answers.count)
        let authorityCount = shouldSerializeRawResourceRecords ? (rawAuthorityCount ?? 0) : UInt16(authorities.count)
        let additionalCount = shouldSerializeRawResourceRecords ? (rawAdditionalCount ?? 0) : UInt16(additional.count)

        guard let newOffset = buffer.copyIn(as: UInt16.self, value: answerCount.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Message", field: "ancount")
        }
        offset = newOffset

        guard let newOffset = buffer.copyIn(as: UInt16.self, value: authorityCount.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Message", field: "nscount")
        }
        offset = newOffset

        guard let newOffset = buffer.copyIn(as: UInt16.self, value: additionalCount.bigEndian, offset: offset) else {
            throw DNSBindError.marshalFailure(type: "Message", field: "arcount")
        }
        offset = newOffset

        // Write questions
        for question in questions {
            offset = try question.appendBuffer(&buffer, offset: offset)
        }

        if shouldSerializeRawResourceRecords, let rawResourceRecords {
            guard let newOffset = buffer.copyIn(buffer: Array(rawResourceRecords), offset: offset) else {
                throw DNSBindError.marshalFailure(type: "Message", field: "resourceRecords")
            }
            offset = newOffset
            guard offset == bufferSize else {
                throw DNSBindError.unexpectedOffset(type: "Message", expected: bufferSize, actual: offset)
            }
            return Data(buffer[0..<offset])
        }

        // Write answers
        for answer in answers {
            offset = try answer.appendBuffer(&buffer, offset: offset)
        }

        // Write authorities
        for authority in authorities {
            offset = try authority.appendBuffer(&buffer, offset: offset)
        }

        // Write additional
        for record in additional {
            offset = try record.appendBuffer(&buffer, offset: offset)
        }

        guard offset == bufferSize else {
            throw DNSBindError.unexpectedOffset(type: "Message", expected: bufferSize, actual: offset)
        }
        return Data(buffer[0..<offset])
    }

    private var shouldSerializeRawResourceRecords: Bool {
        rawResourceRecords != nil && answers.isEmpty && authorities.isEmpty && additional.isEmpty
    }
}
