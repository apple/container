//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

struct StandardQueryValidatorTest {
    @Test func testRejectResponseAsQuery() async throws {
        let fooHandler = FooHandler()
        let handler = StandardQueryValidator(handler: fooHandler)

        let query = Message(
            id: UInt16(1),
            type: .response,
            questions: [
                Question(name: "foo", type: .host)
            ])

        let response = try await handler.answer(query: query)

        #expect(.formatError == response?.returnCode)
        #expect(1 == response?.id)
        #expect(.response == response?.type)
        #expect(1 == response?.questions.count)
        #expect("foo" == response?.questions[0].name)
        #expect(.host == response?.questions[0].type)
        #expect(0 == response?.answers.count)
    }

    @Test func testRejectNonQueryOperation() async throws {
        let fooHandler = FooHandler()
        let handler = StandardQueryValidator(handler: fooHandler)

        let query = Message(
            id: UInt16(2),
            type: .query,
            operationCode: .notify,
            questions: [
                Question(name: "foo", type: .host)
            ])

        let response = try await handler.answer(query: query)

        #expect(.notImplemented == response?.returnCode)
        #expect(2 == response?.id)
        #expect(.response == response?.type)
        #expect(1 == response?.questions.count)
        #expect("foo" == response?.questions[0].name)
        #expect(.host == response?.questions[0].type)
        #expect(0 == response?.answers.count)
    }

    @Test func testRejectMultipleQuestions() async throws {
        let fooHandler = FooHandler()
        let handler = StandardQueryValidator(handler: fooHandler)

        let query = Message(
            id: UInt16(2),
            type: .query,
            questions: [
                Question(name: "foo", type: .host),
                Question(name: "bar", type: .host),
            ])

        let response = try await handler.answer(query: query)

        #expect(.formatError == response?.returnCode)
        #expect(2 == response?.id)
        #expect(.response == response?.type)
        #expect(2 == response?.questions.count)
        #expect("foo" == response?.questions[0].name)
        #expect(.host == response?.questions[0].type)
        #expect("bar" == response?.questions[1].name)
        #expect(.host == response?.questions[1].type)
        #expect(0 == response?.answers.count)
    }

    @Test func testSuccessfulValidation() async throws {
        let fooHandler = FooHandler()
        let handler = StandardQueryValidator(handler: fooHandler)

        let query = Message(
            id: UInt16(2),
            type: .query,
            questions: [
                Question(name: "foo", type: .host)
            ])

        let response = try await handler.answer(query: query)

        #expect(.noError == response?.returnCode)
        #expect(2 == response?.id)
        #expect(.response == response?.type)
        #expect(1 == response?.questions.count)
        #expect("foo" == response?.questions[0].name)
        #expect(.host == response?.questions[0].type)
        #expect(1 == response?.answers.count)
        let answer = response?.answers[0] as? HostRecord<IPv4>
        #expect(IPv4("1.2.3.4") == answer?.ip)
    }
}
