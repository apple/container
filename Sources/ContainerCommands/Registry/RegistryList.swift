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

import ArgumentParser
import ContainerAPIClient
import ContainerizationOCI
import ContainerizationOS
import Foundation

extension Application {
    public struct RegistryList: AsyncLoggableCommand {
        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the registry name")
        var quiet = false

        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List image registry logins",
            aliases: ["ls"])

        public func run() async throws {
            let keychain = KeychainHelper(securityDomain: Constants.keychainID)
            let registries = try keychain.list()
            try printRegistries(registries: registries, format: format)
        }

        private func createHeader() -> [[String]] {
            [["HOSTNAME", "USERNAME", "MODIFIED", "CREATED"]]
        }

        private func printRegistries(registries: [RegistryInfo], format: ListFormat) throws {
            if format == .json {
                let printables = registries.map {
                    PrintableRegistry($0)
                }
                let data = try JSONEncoder().encode(printables)
                print(String(decoding: data, as: UTF8.self))

                return
            }

            if self.quiet {
                registries.forEach {
                    print($0.hostname)
                }
                return
            }

            var rows = createHeader()
            for registry in registries {
                rows.append(registry.asRow)
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }
    }
}
extension RegistryInfo {
    fileprivate var asRow: [String] {
        [
            self.hostname,
            self.username,
            self.modifiedDate.ISO8601Format(),
            self.createdDate.ISO8601Format(),
        ]
    }
}
struct PrintableRegistry: Codable {
    let hostname: String
    let username: String
    let modifiedDate: Date
    let createdDate: Date

    init(_ registry: RegistryInfo) {
        self.hostname = registry.hostname
        self.username = registry.username
        self.modifiedDate = registry.modifiedDate
        self.createdDate = registry.createdDate
    }
}
