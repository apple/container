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

import ArgumentParser
import ContainerAPIClient
import DNSServer
import Foundation

extension Application {
    public struct DNSList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List local DNS domains",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the domain")
        var quiet = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let resolver = HostDNSResolver()
            let domains = resolver.listDomains()

            try Output.render(
                json: domains.map { $0.pqdn },
                display: domains.map { PrintableDomain($0) },
                format: format, quiet: quiet
            )
        }
    }
}

private struct PrintableDomain: ListDisplayable {
    let domain: DNSName

    init(_ domain: DNSName) {
        self.domain = domain
    }

    static var tableHeader: [String] {
        ["DOMAIN"]
    }

    var tableRow: [String] {
        [domain.pqdn]
    }

    var quietValue: String {
        domain.pqdn
    }
}
