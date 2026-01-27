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

/// Handler that uses table lookup to resolve hostnames.
public struct HostTableResolver: DNSHandler {
    public let hosts4: [String: IPv4]
    private let ttl: UInt32

    public init(hosts4: [String: IPv4], ttl: UInt32 = 300) {
        self.hosts4 = hosts4
        self.ttl = ttl
    }

    public func answer(query: Message) async throws -> Message? {
        let question = query.questions[0]
        let record: ResourceRecord?
        switch question.type {
        case ResourceRecordType.host:
            record = answerHost(question: question)
        case ResourceRecordType.host6:
            // Return NODATA (noError with empty answers) for AAAA queries ONLY if A record exists.
            // This is required because musl libc has issues when A record exists but AAAA returns NXDOMAIN.
            // musl treats NXDOMAIN on AAAA as "domain doesn't exist" and fails DNS resolution entirely.
            // NODATA correctly indicates "no IPv6 address available, but domain exists".
            if hosts4[question.name] != nil {
                return Message(
                    id: query.id,
                    type: .response,
                    returnCode: .noError,
                    questions: query.questions,
                    answers: []
                )
            }
            // If hostname doesn't exist, return nil which will become NXDOMAIN
            return nil
        case ResourceRecordType.nameServer,
            ResourceRecordType.alias,
            ResourceRecordType.startOfAuthority,
            ResourceRecordType.pointer,
            ResourceRecordType.mailExchange,
            ResourceRecordType.text,
            ResourceRecordType.service,
            ResourceRecordType.incrementalZoneTransfer,
            ResourceRecordType.standardZoneTransfer,
            ResourceRecordType.all:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .notImplemented,
                questions: query.questions,
                answers: []
            )
        default:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .formatError,
                questions: query.questions,
                answers: []
            )
        }

        guard let record else {
            return nil
        }

        return Message(
            id: query.id,
            type: .response,
            returnCode: .noError,
            questions: query.questions,
            answers: [record]
        )
    }

    private func answerHost(question: Question) -> ResourceRecord? {
        guard let ip = hosts4[question.name] else {
            return nil
        }

        return HostRecord<IPv4>(name: question.name, ttl: ttl, ip: ip)
    }
}
