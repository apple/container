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

import DNS
import Testing

@testable import DNSServer

struct HostTableResolverTest {
    @Test func testUnsupportedQuestionType() async throws {
        guard let ip = IPv4("1.2.3.4") else {
            throw DNSResolverError.serverError("cannot create IP address in test")
        }
        let handler = HostTableResolver(hosts4: ["foo": ip])

        let query = Message(
            id: UInt16(1),
            type: .query,
            questions: [
                Question(name: "foo", type: .host6)
            ])

        let response = try await handler.answer(query: query)

        #expect(.notImplemented == response?.returnCode)
        #expect(1 == response?.id)
        #expect(.response == response?.type)
        #expect(1 == response?.questions.count)
        #expect(0 == response?.answers.count)
    }

    @Test func testHostNotPresent() async throws {
        guard let ip = IPv4("1.2.3.4") else {
            throw DNSResolverError.serverError("cannot create IP address in test")
        }
        let handler = HostTableResolver(hosts4: ["foo": ip])

        let query = Message(
            id: UInt16(1),
            type: .query,
            questions: [
                Question(name: "bar", type: .host)
            ])

        let response = try await handler.answer(query: query)

        #expect(nil == response)
    }

    @Test func testHostPresent() async throws {
        guard let ip = IPv4("1.2.3.4") else {
            throw DNSResolverError.serverError("cannot create IP address in test")
        }
        let handler = HostTableResolver(hosts4: ["foo": ip])

        let query = Message(
            id: UInt16(1),
            type: .query,
            questions: [
                Question(name: "foo", type: .host)
            ])

        let response = try await handler.answer(query: query)

        #expect(.noError == response?.returnCode)
        #expect(1 == response?.id)
        #expect(.response == response?.type)
        #expect(1 == response?.questions.count)
        #expect("foo" == response?.questions[0].name)
        #expect(.host == response?.questions[0].type)
        #expect(1 == response?.answers.count)
        let answer = response?.answers[0] as? HostRecord<IPv4>
        #expect(IPv4("1.2.3.4") == answer?.ip)
    }
}
