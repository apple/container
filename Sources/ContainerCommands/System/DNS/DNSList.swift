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
import Foundation

extension Application {
    public struct DNSList: AsyncParsableCommand {
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
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            let resolver: HostDNSResolver = HostDNSResolver()
            let domains = resolver.listDomains()
            try printDomains(domains: domains, format: format)
        }

        private func createHeader() -> [[String]] {
            [["DOMAIN"]]
        }

        func printDomains(domains: [String], format: ListFormat) throws {
            if format == .json {
                let data = try JSONEncoder().encode(domains)
                print(String(data: data, encoding: .utf8)!)

                return
            }

            if self.quiet {
                domains.forEach { domain in
                    print(domain)
                }
                return
            }

            var rows = createHeader()
            for domain in domains {
                rows.append([domain])
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }

    }
}
