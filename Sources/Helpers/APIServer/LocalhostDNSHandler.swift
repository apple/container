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

import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import DNS
import DNSServer
import Foundation
import Logging

class LocalhostDNSHandler: DNSHandler {
    private let ttl: UInt32
    private let watcher: DirectoryWatcher

    private var dns: [String: IPv4]

    public init(resolversURL: URL = HostDNSResolver.defaultConfigPath, ttl: UInt32 = 5, log: Logger) {
        self.ttl = ttl

        self.watcher = DirectoryWatcher(directoryURL: resolversURL, log: log)
        self.dns = [:]
    }

    public func monitorResolvers() throws {
        try self.watcher.startWatching { fileURLs in
            var dns: [String: IPv4] = [:]
            let regex = try Regex(HostDNSResolver.localhostOptionsRegex)

            for file in fileURLs.filter({ $0.lastPathComponent.starts(with: HostDNSResolver.containerizationPrefix) }) {
                let content = try String(contentsOf: file, encoding: .utf8)

                if let match = content.firstMatch(of: regex),
                    let ipv4 = IPv4(String(match[1].substring ?? ""))
                {
                    let name = String(file.lastPathComponent.dropFirst(HostDNSResolver.containerizationPrefix.count))
                    dns[name + "."] = ipv4
                }
            }
            self.dns = dns
        }
    }

    public func answer(query: Message) async throws -> Message? {
        let question = query.questions[0]
        var record: ResourceRecord?
        switch question.type {
        case ResourceRecordType.host:
            if let ip = dns[question.name] {
                record = HostRecord<IPv4>(name: question.name, ttl: ttl, ip: ip)
            }
        case ResourceRecordType.host6:
            return Message(
                id: query.id,
                type: .response,
                returnCode: .noError,
                questions: query.questions,
                answers: []
            )
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
}
