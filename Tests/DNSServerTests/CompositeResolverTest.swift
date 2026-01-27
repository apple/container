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

struct CompositeResolverTest {
    @Test func testCompositeResolver() async throws {
        let foo = FooHandler()
        let bar = BarHandler()
        let resolver = CompositeResolver(handlers: [foo, bar])

        let fooQuery = Message(
            id: UInt16(1),
            type: .query,
            questions: [
                Question(name: "foo", type: .host)
            ])

        let fooResponse = try await resolver.answer(query: fooQuery)
        #expect(.noError == fooResponse?.returnCode)
        #expect(1 == fooResponse?.id)
        #expect(1 == fooResponse?.answers.count)
        let fooAnswer = fooResponse?.answers[0] as? HostRecord<IPv4>
        #expect(IPv4("1.2.3.4") == fooAnswer?.ip)

        let barQuery = Message(
            id: UInt16(1),
            type: .query,
            questions: [
                Question(name: "bar", type: .host)
            ])

        let barResponse = try await resolver.answer(query: barQuery)
        #expect(.noError == barResponse?.returnCode)
        #expect(1 == barResponse?.id)
        #expect(1 == barResponse?.answers.count)
        let barAnswer = barResponse?.answers[0] as? HostRecord<IPv4>
        #expect(IPv4("5.6.7.8") == barAnswer?.ip)

        let otherQuery = Message(
            id: UInt16(1),
            type: .query,
            questions: [
                Question(name: "other", type: .host)
            ])

        let otherResponse = try await resolver.answer(query: otherQuery)
        #expect(nil == otherResponse)
    }
}
