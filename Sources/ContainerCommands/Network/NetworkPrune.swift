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

extension Application.NetworkCommand {
    public struct NetworkPrune: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove networks with no container connections"
        )

        @OptionGroup
        var global: Flags.Global

        public func run() async throws {
            let allContainers = try await ClientContainer.list()
            let allNetworks = try await ClientNetwork.list()

            var networksInUse = Set<String>()
            for container in allContainers {
                for network in container.configuration.networks {
                    networksInUse.insert(network.network)
                }
            }

            let networksToPrune = allNetworks.filter { network in
                network.id != ClientNetwork.defaultNetworkName && !networksInUse.contains(network.id)
            }

            var prunedNetworks = [String]()

            for network in networksToPrune {
                do {
                    try await ClientNetwork.delete(id: network.id)
                    prunedNetworks.append(network.id)
                } catch {
                    // Note: This failure may occur due to a race condition between the network/
                    // container collection above and a container run command that attaches to a
                    // network listed in the networksToPrune collection.
                    log.error("Failed to prune network \(network.id): \(error)")
                }
            }

            for name in prunedNetworks {
                print(name)
            }
        }
    }
}
