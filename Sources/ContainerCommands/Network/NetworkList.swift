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
import ContainerResource
import ContainerizationExtras
import Foundation
import SwiftProtobuf

extension Application {
    public struct NetworkList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List networks",
            aliases: ["ls"])

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the network name")
        var quiet = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let networks = try await ClientNetwork.list()
            try printNetworks(networks: networks, format: format)
        }

        private func createHeader() -> [[String]] {
            [["NETWORK", "STATE", "SUBNET"]]
        }

        func printNetworks(networks: [NetworkState], format: ListFormat) throws {
            if format == .json {
                let printables = networks.map {
                    PrintableNetwork($0)
                }
                let data = try JSONEncoder().encode(printables)
                print(String(data: data, encoding: .utf8)!)

                return
            }

            if self.quiet {
                networks.forEach {
                    print($0.id)
                }
                return
            }

            var rows = createHeader()
            for network in networks {
                rows.append(network.asRow)
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }
    }
}

extension NetworkState {
    var asRow: [String] {
        switch self {
        case .created(_):
            return [self.id, self.state, "none"]
        case .running(_, let status):
            return [self.id, self.state, status.ipv4Subnet.description]
        }
    }
}

public struct PrintableNetwork: Codable {
    let id: String
    let state: String
    let config: NetworkConfiguration
    let status: NetworkStatus?

    public init(_ network: NetworkState) {
        self.id = network.id
        self.state = network.state
        switch network {
        case .created(let config):
            self.config = config
            self.status = nil
        case .running(let config, let status):
            self.config = config
            self.status = status
        }
    }
}
