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
import ContainerClient
import ContainerNetworkService
import ContainerizationError
import ContainerizationExtras
import Foundation
import TerminalProgress

extension Application {
    public struct NetworkCreate: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new network")

        @Option(name: .customLong("label"), help: "Set metadata for a network")
        var labels: [String] = []

        @Option(name: .customLong("subnet"), help: "Set subnet for a network")
        var ipv4Subnet: String? = nil

        @Option(name: .customLong("subnet-v6"), help: "Set the IPv6 prefix for a network")
        var ipv6Subnet: String? = nil

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Network name")
        var name: String

        public init() {}

        public func run() async throws {
            let parsedLabels = Utility.parseKeyValuePairs(labels)
            let ipv4Subnet = try ipv4Subnet.map { try CIDRv4($0) }
            let ipv6Subnet = try ipv6Subnet.map { try CIDRv6($0) }
            let config = try NetworkConfiguration(id: self.name, mode: .nat, ipv4Subnet: ipv4Subnet, ipv6Subnet: ipv6Subnet, labels: parsedLabels)
            let state = try await ClientNetwork.create(configuration: config)
            print(state.id)
        }
    }
}
