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

/// Handler that returns NXDOMAIN for all hostnames.
public struct NxDomainResolver: DNSHandler {
    private let ttl: UInt32

    public init(ttl: UInt32 = 300) {
        self.ttl = ttl
    }

    public func answer(query: Message) async throws -> Message? {
        let question = query.questions[0]
        switch question.type {
        case ResourceRecordType.host:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .nonExistentDomain,
                questions: query.questions,
                answers: []
            )
        default:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .notImplemented,
                questions: query.questions,
                answers: []
            )
        }
    }
}
