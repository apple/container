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
        func createFromString() {
            let name = DNSName("example.com")
            #expect(name.labels == ["example", "com"])
        }

        @Test("Create from string with trailing dot")
        func createFromStringTrailingDot() {
            let name = DNSName("example.com.")
            #expect(name.labels == ["example", "com"])
        }

        @Test("Description includes trailing dot")
        func descriptionTrailingDot() {
            let name = DNSName("example.com")
            #expect(name.description == "example.com.")
        }

        @Test("Root domain")
        func rootDomain() {
            let name = DNSName("")
            #expect(name.labels == [])
            #expect(name.description == ".")
        }

        @Test("Size calculation")
        func sizeCalculation() {
            let name = DNSName("example.com")
            // [7]example[3]com[0] = 1 + 7 + 1 + 3 + 1 = 13
            #expect(name.size == 13)
        }

        @Test("Serialize and deserialize")
        func serializeDeserialize() throws {
            let original = DNSName("test.example.com")
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try original.appendBuffer(&buffer, offset: 0)

            var parsed = DNSName()
            let readOffset = try parsed.bindBuffer(&buffer, offset: 0)

            #expect(readOffset == endOffset)
            #expect(parsed.labels == original.labels)
        }

        @Test("Serialize subdomain")
        func serializeSubdomain() throws {
            let name = DNSName("a.b.c.d.example.com")
            var buffer = [UInt8](repeating: 0, count: 64)

            _ = try name.appendBuffer(&buffer, offset: 0)

            var parsed = DNSName()
            _ = try parsed.bindBuffer(&buffer, offset: 0)

            #expect(parsed.labels == ["a", "b", "c", "d", "example", "com"])
        }

        @Test("Reject label too long")
        func rejectLabelTooLong() {
            let longLabel = String(repeating: "a", count: 64)
            let name = DNSName(longLabel + ".com")
            var buffer = [UInt8](repeating: 0, count: 128)

            #expect(throws: DNSBindError.self) {
                _ = try name.appendBuffer(&buffer, offset: 0)
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

            #expect(readOffset == endOffset)
            #expect(parsed.type == .host)
            #expect(parsed.recordClass == .internet)
        }

        @Test("Serialize and deserialize AAAA record question")
        func serializeDeserializeAAAA() throws {
            let original = Question(name: "example.com.", type: .host6, recordClass: .internet)
            var buffer = [UInt8](repeating: 0, count: 64)

            _ = try original.appendBuffer(&buffer, offset: 0)

            var parsed = Question(name: "")
            _ = try parsed.bindBuffer(&buffer, offset: 0)

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

            // Should have written: name + type(2) + class(2) + ttl(4) + rdlen(2) + rdata(4)
            #expect(endOffset > 0)

            // Verify IP bytes are at the end
            let ipStart = endOffset - 4
            #expect(buffer[ipStart] == 10)
            #expect(buffer[ipStart + 1] == 0)
            #expect(buffer[ipStart + 2] == 0)
            #expect(buffer[ipStart + 3] == 1)
        }

        @Test("Serialize AAAA record")
        func serializeAAAARecord() throws {
            let ip = try IPv6Address("::1")
            let record = HostRecord(name: "test.com.", ttl: 300, ip: ip)
            var buffer = [UInt8](repeating: 0, count: 64)

            let endOffset = try record.appendBuffer(&buffer, offset: 0)

            // Verify last byte is 1 (::1)
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
    }
}
