//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerAPIService
import DNS
import DNSServer

/// Handler that uses table lookup to resolve hostnames.
struct ContainerDNSHandler: DNSHandler {
    private let networkService: NetworksService
    private let ttl: UInt32

    public init(networkService: NetworksService, ttl: UInt32 = 5) {
        self.networkService = networkService
        self.ttl = ttl
    }

    public func answer(query: Message) async throws -> Message? {
        let question = query.questions[0]
        let record: ResourceRecord?
        switch question.type {
        case ResourceRecordType.host:
            record = try await answerHost(question: question)
        case ResourceRecordType.nameServer,
            ResourceRecordType.alias,
            ResourceRecordType.startOfAuthority,
            ResourceRecordType.pointer,
            ResourceRecordType.mailExchange,
            ResourceRecordType.text,
            ResourceRecordType.host6,
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

    private func answerHost(question: Question) async throws -> ResourceRecord? {
        guard let ipAllocation = try await networkService.lookup(hostname: question.name) else {
            return nil
        }

        let components = ipAllocation.address.split(separator: "/")
        guard !components.isEmpty else {
            throw DNSResolverError.serverError("Invalid IP format: empty address")
        }

        let ipString = String(components[0])
        guard let ip = IPv4(ipString) else {
            throw DNSResolverError.serverError("Failed to parse IP address: \(ipString)")
        }

        return HostRecord<IPv4>(name: question.name, ttl: ttl, ip: ip)
    }
}
