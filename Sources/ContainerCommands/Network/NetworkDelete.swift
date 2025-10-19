//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import Foundation

extension Application {
    public struct NetworkDelete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one or more networks",
            aliases: ["rm"])

        @Flag(name: .shortAndLong, help: "Delete all networks")
        var all = false

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Network names")
        var networkNames: [String] = []

        public init() {}

        public func validate() throws {
            if networkNames.count == 0 && !all {
                throw ContainerizationError(.invalidArgument, message: "no networks specified and --all not supplied")
            }
            if networkNames.count > 0 && all {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "explicitly supplied network name(s) conflict with the --all flag"
                )
            }
        }

        public mutating func run() async throws {
            let uniqueNetworkNames = Set<String>(networkNames)
            let networks: [NetworkState]

            if all {
                networks = try await ClientNetwork.list()
            } else {
                networks = try await ClientNetwork.list()
                    .filter { c in
                        uniqueNetworkNames.contains(c.id)
                    }

                // If one of the networks requested isn't present lets throw. We don't need to do
                // this for --all as --all should be perfectly usable with no networks to remove,
                // otherwise it'd be quite clunky.
                if networks.count != uniqueNetworkNames.count {
                    let missing = uniqueNetworkNames.filter { id in
                        !networks.contains { n in
                            n.id == id
                        }
                    }
                    throw ContainerizationError(
                        .notFound,
                        message: "failed to delete one or more networks: \(missing)"
                    )
                }
            }

            if uniqueNetworkNames.contains(ClientNetwork.defaultNetworkName) {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "cannot delete the default network"
                )
            }

            var failed = [String]()
            try await withThrowingTaskGroup(of: NetworkState?.self) { group in
                for network in networks {
                    group.addTask {
                        do {
                            // Delete atomically disables the IP allocator, then deletes
                            // the allocator. The disable fails if any IPs are still in use.
                            try await ClientNetwork.delete(id: network.id)
                            print(network.id)
                            return nil
                        } catch {
                            log.error("failed to delete network \(network.id): \(error)")
                            return network
                        }
                    }
                }

                for try await network in group {
                    guard let network else {
                        continue
                    }
                    failed.append(network.id)
                }
            }

            if failed.count > 0 {
                throw ContainerizationError(.internalError, message: "delete failed for one or more networks: \(failed)")
            }
        }
    }
}
