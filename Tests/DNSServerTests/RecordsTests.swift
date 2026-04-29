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

import ContainerizationExtras
import Foundation
import Testing

@testable import DNSServer

@Suite("DNS Records Tests")
struct RecordsTests {

    // MARK: - DNSName Tests

    @Suite("DNSName")
    struct DNSNameTests {
        @Test("Create from string")
        func createFromString() throws {
            let name = try DNSName("example.com")
            #expect(name.labels == ["example", "com"])
        }

        @Test("Create from string with trailing dot")
        func createFromStringTrailingDot() throws {
            let name = try DNSName("example.com.")
            #expect(name.labels == ["example", "com"])
        }

        @Test("Description includes trailing dot")
        func descriptionTrailingDot() throws {
            let name = try DNSName("example.com")
            #expect(name.description == "example.com.")
        }

        @Test("Root domain")
        func rootDomain() throws {
            let name = try DNSName("")
            #expect(name.labels == [])
            #expect(name.description == ".")
        }

        @Test("Size calculation")
        func sizeCalculation() throws {
            let name = try DNSName("example.com")
            // [7]example[3]com[0] = 1 + 7 + 1 + 3 + 1 = 13
            #expect(name.size == 13)
        }

        @Test("Serialize and deserialize")
        func serializeDeserialize() throws {
            let original = try DNSName("test.example.com")
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try original.appendBuffer(&buffer, offset: 0)

            var parsed = DNSName()
            let readOffset = try parsed.bindBuffer(&buffer, offset: 0)

            // [4]test[7]example[3]com[0] = 5+8+4+1 = 18
            #expect(endOffset == 18)
            #expect(readOffset == endOffset)
            #expect(parsed.labels == original.labels)
        }

        @Test("Serialize subdomain")
        func serializeSubdomain() throws {
            let name = try DNSName("a.b.c.d.example.com")
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try name.appendBuffer(&buffer, offset: 0)

            var parsed = DNSName()
            let readOffset = try parsed.bindBuffer(&buffer, offset: 0)

            // [1]a[1]b[1]c[1]d[7]example[3]com[0] = 2+2+2+2+8+4+1 = 21
            #expect(endOffset == 21)
            #expect(readOffset == endOffset)
            #expect(parsed.labels == ["a", "b", "c", "d", "example", "com"])
        }

        @Test("Reject label too long")
        func rejectLabelTooLong() {
            let longLabel = String(repeating: "a", count: 64)
            #expect(throws: DNSBindError.self) {
                _ = try DNSName(longLabel + ".com")
            }
        }

        @Test("Reject embedded carriage return")
        func rejectEmbeddedCarriageReturn() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("foo\r.com")
            }
        }

        @Test("Reject embedded newline")
        func rejectEmbeddedNewline() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("foo\n.com")
            }
        }

        @Test("Reject embedded null byte")
        func rejectEmbeddedNullByte() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("foo\0.com")
            }
        }

        @Test("Reject empty label")
        func rejectEmptyLabel() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("foo..com")
            }
        }

        @Test("Reject name too long")
        func rejectNameTooLong() {
            // 9 labels * (1 + 30) bytes + 1 null = 280 bytes > 255
            let label = String(repeating: "a", count: 30)
            let name = Array(repeating: label, count: 9).joined(separator: ".")
            #expect(throws: DNSBindError.self) {
                _ = try DNSName(name)
            }
        }

        @Test("Reject leading hyphen")
        func rejectLeadingHyphen() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("-foo.com")
            }
        }

        @Test("Reject trailing hyphen")
        func rejectTrailingHyphen() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("foo-.com")
            }
        }

        @Test("Reject leading underscore")
        func rejectLeadingUnderscore() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("_foo.com")
            }
        }

        @Test("Reject trailing underscore")
        func rejectTrailingUnderscore() {
            #expect(throws: DNSBindError.self) {
                _ = try DNSName("foo_.com")
            }
        }

        @Test("Accept service labels via init(labels:)")
        func acceptServiceLabels() throws {
            let name = try DNSName(labels: ["_dns-sd", "_udp", "local"])
            #expect(name.labels == ["_dns-sd", "_udp", "local"])
        }

        @Test("Lowercase labels on init")
        func lowercaseLabelsOnInit() throws {
            let name = try DNSName("EXAMPLE.COM")
            #expect(name.labels == ["example", "com"])
        }

        @Test("Lowercase labels on init with trailing dot")
        func lowercaseLabelsOnInitTrailingDot() throws {
            let name = try DNSName("Example.Com.")
            #expect(name.labels == ["example", "com"])
        }

        @Test("Lowercase labels from wire format")
        func lowercaseLabelsFromWire() throws {
            // Wire-encode "EXAMPLE.COM" with uppercase bytes, then decode
            let upper = try DNSName(labels: ["EXAMPLE", "COM"])
            var buffer = [UInt8](repeating: 0, count: 64)
            let endOffset = try upper.appendBuffer(&buffer, offset: 0)

            var parsed = DNSName()
            let readOffset = try parsed.bindBuffer(&buffer, offset: 0)

            // [7]example[3]com[0] = 8+4+1 = 13
            #expect(endOffset == 13)
            #expect(readOffset == endOffset)
            #expect(parsed.labels == ["example", "com"])
        }

        @Test("Follow valid compression pointer")
        func followCompressionPointer() throws {
            // Build a buffer with two names:
            //   offset  0: "example.com." — [7]example[3]com[0] (13 bytes)
            //   offset 13: "test."        — [4]test 0xC0 0x00   ( 7 bytes)
            // The pointer 0xC0 0x00 points back to offset 0.
            var buffer: [UInt8] = [
                0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,  // [7]example
                0x03, 0x63, 0x6f, 0x6d,  // [3]com
                0x00,  // null terminator
                0x04, 0x74, 0x65, 0x73, 0x74,  // [4]test
                0xC0, 0x00,  // pointer to offset 0
            ]

            var name = DNSName()
            let readOffset = try name.bindBuffer(&buffer, offset: 13)

            // Pointer bytes are at offset 18–19; returnOffset = 18 + 2 = 20
            #expect(readOffset == 20)
            #expect(name.labels == ["test", "example", "com"])
        }

        @Test("Reject forward compression pointer")
        func rejectForwardCompressionPointer() throws {
            // Craft a packet with a forward compression pointer at offset 12 pointing to offset 20
            // Header (12 bytes) + pointer bytes
            var buffer = [UInt8](repeating: 0, count: 32)
            // At offset 0: compression pointer to offset 20 (forward)
            buffer[0] = 0xC0
            buffer[1] = 0x14  // points to offset 20, which is > 0

            #expect(throws: DNSBindError.self) {
                var b = buffer
                var name = DNSName()
                _ = try name.bindBuffer(&b, offset: 0)
            }
        }

        @Test("Reject self-referential compression pointer")
        func rejectSelfReferentialCompressionPointer() throws {
            var buffer = [UInt8](repeating: 0, count: 16)
            // At offset 0: compression pointer pointing back to offset 0 (same location)
            buffer[0] = 0xC0
            buffer[1] = 0x00  // points to offset 0 == current offset, not prior

            #expect(throws: DNSBindError.self) {
                var b = buffer
                var name = DNSName()
                _ = try name.bindBuffer(&b, offset: 0)
            }
        }

        @Test("Reject compression pointer hop limit exceeded")
        func rejectCompressionPointerHopLimit() throws {
            // Build a chain of backward pointers:
            //   offset  0: [1]a[0]          — terminal name (3 bytes)
            //   offset  3: 0xC0 0x00        — pointer → 0
            //   offset  5: 0xC0 0x03        — pointer → 3
            //   ...each entry points to the one before it...
            //   offset 23: 0xC0 0x15        — pointer → 21
            //   offset 25: 0xC0 0x17        — pointer → 23
            //
            // Reading from offset 25 follows 11 hops (25→23→21→...→3→0),
            // which exceeds the limit of 10.
            var buffer: [UInt8] = [
                0x01, 0x61, 0x00,  // offset  0: [1]a[0]
                0xC0, 0x00,  // offset  3: → 0
                0xC0, 0x03,  // offset  5: → 3
                0xC0, 0x05,  // offset  7: → 5
                0xC0, 0x07,  // offset  9: → 7
                0xC0, 0x09,  // offset 11: → 9
                0xC0, 0x0B,  // offset 13: → 11
                0xC0, 0x0D,  // offset 15: → 13
                0xC0, 0x0F,  // offset 17: → 15
                0xC0, 0x11,  // offset 19: → 17
                0xC0, 0x13,  // offset 21: → 19
                0xC0, 0x15,  // offset 23: → 21
                0xC0, 0x17,  // offset 25: → 23
            ]

            #expect(throws: DNSBindError.self) {
                var name = DNSName()
                _ = try name.bindBuffer(&buffer, offset: 25)
            }
        }
    }

    // MARK: - Question Tests

    @Suite("Question")
    struct QuestionTests {
        @Test("Create question")
        func create() {
            let q = Question(name: "example.com.", type: .host, recordClass: .internet)
            #expect(q.name == "example.com.")
            #expect(q.type == .host)
            #expect(q.recordClass == .internet)
        }

        @Test("Serialize and deserialize A record question")
        func serializeDeserializeA() throws {
            let original = Question(name: "example.com.", type: .host, recordClass: .internet)
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try original.appendBuffer(&buffer, offset: 0)

            var parsed = Question(name: "")
            let readOffset = try parsed.bindBuffer(&buffer, offset: 0)

            // name([7]example[3]com[0]=13) + type(2) + class(2) = 17
            #expect(endOffset == 17)
            #expect(readOffset == endOffset)
            #expect(parsed.type == .host)
            #expect(parsed.recordClass == .internet)
        }

        @Test("Serialize and deserialize AAAA record question")
        func serializeDeserializeAAAA() throws {
            let original = Question(name: "example.com.", type: .host6, recordClass: .internet)
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try original.appendBuffer(&buffer, offset: 0)

            var parsed = Question(name: "")
            let readOffset = try parsed.bindBuffer(&buffer, offset: 0)

            // name([7]example[3]com[0]=13) + type(2) + class(2) = 17
            #expect(endOffset == 17)
            #expect(readOffset == endOffset)
            #expect(parsed.type == .host6)
        }
    }

    // MARK: - HostRecord Tests

    @Suite("HostRecord")
    struct HostRecordTests {
        @Test("Create A record")
        func createARecord() throws {
            let ip = try IPv4Address("192.168.1.1")
            let record = HostRecord(name: "example.com.", ttl: 300, ip: ip)

            #expect(record.name == "example.com.")
            #expect(record.type == .host)
            #expect(record.ttl == 300)
            #expect(record.ip == ip)
        }

        @Test("Create AAAA record")
        func createAAAARecord() throws {
            let ip = try IPv6Address("::1")
            let record = HostRecord(name: "example.com.", ttl: 600, ip: ip)

            #expect(record.name == "example.com.")
            #expect(record.type == .host6)
            #expect(record.ttl == 600)
        }

        @Test("Serialize A record")
        func serializeARecord() throws {
            let ip = try IPv4Address("10.0.0.1")
            let record = HostRecord(name: "test.com.", ttl: 300, ip: ip)
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try record.appendBuffer(&buffer, offset: 0)

            // name([4]test[3]com[0]=10) + type(2) + class(2) + ttl(4) + rdlen(2) + rdata(4) = 24
            #expect(endOffset == 24)

            // Verify IP bytes at the end
            #expect(buffer[endOffset - 4] == 10)
            #expect(buffer[endOffset - 3] == 0)
            #expect(buffer[endOffset - 2] == 0)
            #expect(buffer[endOffset - 1] == 1)
        }

        @Test("Serialize AAAA record")
        func serializeAAAARecord() throws {
            let ip = try IPv6Address("::1")
            let record = HostRecord(name: "test.com.", ttl: 300, ip: ip)
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try record.appendBuffer(&buffer, offset: 0)

            // name([4]test[3]com[0]=10) + type(2) + class(2) + ttl(4) + rdlen(2) + rdata(16) = 36
            #expect(endOffset == 36)
            #expect(buffer[endOffset - 1] == 1)
        }
    }

    // MARK: - Message Tests

    @Suite("Message")
    struct MessageTests {
        @Test("Create query message")
        func createQuery() {
            let msg = Message(
                id: 0x1234,
                type: .query,
                questions: [Question(name: "example.com.", type: .host)]
            )

            #expect(msg.id == 0x1234)
            #expect(msg.type == .query)
            #expect(msg.questions.count == 1)
        }

        @Test("Create response message")
        func createResponse() throws {
            let ip = try IPv4Address("192.168.1.1")
            let msg = Message(
                id: 0x1234,
                type: .response,
                returnCode: .noError,
                questions: [Question(name: "example.com.", type: .host)],
                answers: [HostRecord(name: "example.com.", ttl: 300, ip: ip)]
            )

            #expect(msg.type == .response)
            #expect(msg.returnCode == .noError)
            #expect(msg.answers.count == 1)
        }

        @Test("Serialize and deserialize query")
        func serializeDeserializeQuery() throws {
            let original = Message(
                id: 0xABCD,
                type: .query,
                recursionDesired: true,
                questions: [Question(name: "example.com.", type: .host)]
            )

            let data = try original.serialize()
            let parsed = try Message(deserialize: data)

            #expect(parsed.id == 0xABCD)
            #expect(parsed.type == .query)
            #expect(parsed.recursionDesired == true)
            #expect(parsed.questions.count == 1)
            #expect(parsed.questions[0].type == .host)
        }

        @Test("Serialize response with answer")
        func serializeResponse() throws {
            let ip = try IPv4Address("10.0.0.1")
            let msg = Message(
                id: 0x1234,
                type: .response,
                authoritativeAnswer: true,
                returnCode: .noError,
                questions: [Question(name: "test.com.", type: .host)],
                answers: [HostRecord(name: "test.com.", ttl: 300, ip: ip)]
            )

            let data = try msg.serialize()

            // Verify we can at least parse the header back
            let parsed = try Message(deserialize: data)
            #expect(parsed.id == 0x1234)
            #expect(parsed.type == .response)
            #expect(parsed.authoritativeAnswer == true)
            #expect(parsed.returnCode == .noError)
        }

        @Test("Serialize NXDOMAIN response")
        func serializeNxdomain() throws {
            let msg = Message(
                id: 0x1234,
                type: .response,
                returnCode: .nonExistentDomain,
                questions: [Question(name: "unknown.com.", type: .host)],
                answers: []
            )

            let data = try msg.serialize()
            let parsed = try Message(deserialize: data)

            #expect(parsed.returnCode == .nonExistentDomain)
            #expect(parsed.answers.count == 0)
        }

        @Test("Serialize NODATA response (empty answers with noError)")
        func serializeNodata() throws {
            let msg = Message(
                id: 0x1234,
                type: .response,
                returnCode: .noError,
                questions: [Question(name: "example.com.", type: .host6)],
                answers: []
            )

            let data = try msg.serialize()
            let parsed = try Message(deserialize: data)

            #expect(parsed.returnCode == .noError)
            #expect(parsed.answers.count == 0)
        }

        @Test("Multiple questions")
        func multipleQuestions() throws {
            let msg = Message(
                id: 0x1234,
                type: .query,
                questions: [
                    Question(name: "a.com.", type: .host),
                    Question(name: "b.com.", type: .host6),
                ]
            )

            let data = try msg.serialize()
            let parsed = try Message(deserialize: data)

            #expect(parsed.questions.count == 2)
            #expect(parsed.questions[0].type == .host)
            #expect(parsed.questions[1].type == .host6)
        }

        @Test("Reject too many questions")
        func rejectTooManyQuestions() {
            let questions = Array(repeating: Question(name: "a.com.", type: .host), count: Int(UInt16.max) + 1)
            let msg = Message(id: 0, type: .query, questions: questions)
            #expect(throws: DNSBindError.self) {
                _ = try msg.serialize()
            }
        }

        @Test("Reject too many answers")
        func rejectTooManyAnswers() throws {
            let ip = try IPv4Address("1.2.3.4")
            let answers = Array(repeating: HostRecord(name: "a.com.", ttl: 0, ip: ip), count: Int(UInt16.max) + 1)
            let msg = Message(id: 0, type: .response, answers: answers)
            #expect(throws: DNSBindError.self) {
                _ = try msg.serialize()
            }
        }
    }

    // MARK: - Wire Format Tests

    @Suite("Wire Format")
    struct WireFormatTests {
        @Test("Parse real DNS query bytes")
        func parseRealQuery() throws {
            // A minimal DNS query for "example.com" A record
            // Header: ID=0x1234, QR=0, OPCODE=0, RD=1, QDCOUNT=1
            let queryBytes: [UInt8] = [
                0x12, 0x34,  // ID
                0x01, 0x00,  // Flags: RD=1
                0x00, 0x01,  // QDCOUNT=1
                0x00, 0x00,  // ANCOUNT=0
                0x00, 0x00,  // NSCOUNT=0
                0x00, 0x00,  // ARCOUNT=0
                // Question: example.com A IN
                0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,  // "example"
                0x03, 0x63, 0x6f, 0x6d,  // "com"
                0x00,  // null terminator
                0x00, 0x01,  // QTYPE=A
                0x00, 0x01,  // QCLASS=IN
            ]

            let msg = try Message(deserialize: Data(queryBytes))

            #expect(msg.id == 0x1234)
            #expect(msg.type == .query)
            #expect(msg.recursionDesired == true)
            #expect(msg.questions.count == 1)
            #expect(msg.questions[0].type == .host)
            #expect(msg.questions[0].recordClass == .internet)
        }

        @Test("Roundtrip preserves data")
        func roundtrip() throws {
            let ip = try IPv4Address("1.2.3.4")
            let original = Message(
                id: 0xBEEF,
                type: .response,
                operationCode: .query,
                authoritativeAnswer: true,
                truncation: false,
                recursionDesired: true,
                recursionAvailable: true,
                returnCode: .noError,
                questions: [Question(name: "test.example.com.", type: .host)],
                answers: [HostRecord(name: "test.example.com.", ttl: 3600, ip: ip)]
            )

            let data = try original.serialize()
            let parsed = try Message(deserialize: data)

            #expect(parsed.id == original.id)
            #expect(parsed.type == original.type)
            #expect(parsed.authoritativeAnswer == original.authoritativeAnswer)
            #expect(parsed.truncation == original.truncation)
            #expect(parsed.recursionDesired == original.recursionDesired)
            #expect(parsed.recursionAvailable == original.recursionAvailable)
            #expect(parsed.returnCode == original.returnCode)
            #expect(parsed.questions.count == original.questions.count)
        }

        @Test("Reject unknown opcode")
        func rejectUnknownOpcode() {
            // Opcode occupies bits 14–11 of the flags word. Value 3 is reserved.
            // Flags: 0x18 0x00 = QR=0, OPCODE=3, all other bits clear.
            let bytes: [UInt8] = [
                0x00, 0x01,  // ID
                0x18, 0x00,  // Flags: OPCODE=3 (reserved)
                0x00, 0x00,  // QDCOUNT=0
                0x00, 0x00,  // ANCOUNT=0
                0x00, 0x00,  // NSCOUNT=0
                0x00, 0x00,  // ARCOUNT=0
            ]
            #expect(throws: DNSBindError.self) {
                _ = try Message(deserialize: Data(bytes))
            }
        }

        @Test("Reject unknown RCODE")
        func rejectUnknownRcode() {
            // RCODE occupies bits 3–0 of the flags word. Value 12 is reserved.
            // Flags: 0x00 0x0C = QR=0, OPCODE=0, RCODE=12.
            let bytes: [UInt8] = [
                0x00, 0x01,  // ID
                0x00, 0x0C,  // Flags: RCODE=12 (reserved)
                0x00, 0x00,  // QDCOUNT=0
                0x00, 0x00,  // ANCOUNT=0
                0x00, 0x00,  // NSCOUNT=0
                0x00, 0x00,  // ARCOUNT=0
            ]
            #expect(throws: DNSBindError.self) {
                _ = try Message(deserialize: Data(bytes))
            }
        }

        @Test("Reject unknown query type")
        func rejectUnknownQueryType() {
            // Type 54 is unassigned in the IANA DNS parameters registry.
            let bytes: [UInt8] = [
                0x00, 0x01,  // ID
                0x00, 0x00,  // Flags: standard query
                0x00, 0x01,  // QDCOUNT=1
                0x00, 0x00,  // ANCOUNT=0
                0x00, 0x00,  // NSCOUNT=0
                0x00, 0x00,  // ARCOUNT=0
                0x01, 0x61, 0x00,  // name: [1]a[0]
                0x00, 0x36,  // QTYPE=54 (unassigned)
                0x00, 0x01,  // QCLASS=IN
            ]
            #expect(throws: DNSBindError.self) {
                _ = try Message(deserialize: Data(bytes))
            }
        }

        @Test("Reject unknown record class")
        func rejectUnknownRecordClass() {
            // Class 2 is unassigned in the IANA DNS parameters registry.
            let bytes: [UInt8] = [
                0x00, 0x01,  // ID
                0x00, 0x00,  // Flags: standard query
                0x00, 0x01,  // QDCOUNT=1
                0x00, 0x00,  // ANCOUNT=0
                0x00, 0x00,  // NSCOUNT=0
                0x00, 0x00,  // ARCOUNT=0
                0x01, 0x61, 0x00,  // name: [1]a[0]
                0x00, 0x01,  // QTYPE=A
                0x00, 0x02,  // QCLASS=2 (unassigned)
            ]
            #expect(throws: DNSBindError.self) {
                _ = try Message(deserialize: Data(bytes))
            }
        }
    }
}
