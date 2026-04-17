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
import ContainerResource
import ContainerizationOCI
import ContainerizationOS
import Foundation

extension Application {
    public struct RegistryList: AsyncLoggableCommand {
        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the registry hostname")
        var quiet = false

        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List image registry logins",
            aliases: ["ls"])

        public func run() async throws {
            let keychain = KeychainHelper(securityDomain: Constants.keychainID)
            let registryInfos = try keychain.list()
            let registries = registryInfos.map { RegistryResource(from: $0) }

            try Output.render(
                json: registries,
                display: registries.map { PrintableRegistry($0) },
                format: format, quiet: quiet
            )
        }
    }
}

private struct PrintableRegistry: ListDisplayable {
    let registry: RegistryResource

    init(_ registry: RegistryResource) {
        self.registry = registry
    }

    static var tableHeader: [String] {
        ["HOSTNAME", "USERNAME", "MODIFIED", "CREATED"]
    }

    var tableRow: [String] {
        [
            registry.name,
            registry.username,
            registry.modificationDate.ISO8601Format(),
            registry.creationDate.ISO8601Format(),
        ]
    }

    var quietValue: String {
        registry.name
    }
}
