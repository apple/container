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
    public struct NetworkPrune: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove networks not connected to any containers")

        @OptionGroup
        var global: Flags.Global

        public func run() async throws {
            let networks = try await ClientNetwork.list()
            let containers = try await ClientContainer.list()
            let networksInUse = Set<String>(
                containers.flatMap { container in
                    container.networks.map { $0.network } + container.configuration.networks.map { $0.network }
                }
            )
            let networksToPrune = networks.filter { network in
                if network.id == ClientNetwork.defaultNetworkName {
                    return false
                }
                guard case .running = network else {
                    return false
                }
                return !networksInUse.contains(network.id)
            }

            var failed = [String]()

            if !networksToPrune.isEmpty {
                try await withThrowingTaskGroup(of: (String, Bool).self) { group in
                    for network in networksToPrune {
                        group.addTask {
                            do {
                                try await ClientNetwork.delete(id: network.id)
                                return (network.id, true)
                            } catch {
                                // A failure here can happen when a container attached to the network
                                // after we collected the state above (race with `container run --network`).
                                log.error("failed to delete network \(network.id): \(error)")
                                return (network.id, false)
                            }
                        }
                    }

                    for try await (networkId, success) in group {
                        if success {
                            print(networkId)
                        } else {
                            failed.append(networkId)
                        }
                    }
                }
            }

            if failed.count > 0 {
                throw ContainerizationError(.internalError, message: "failed to prune one or more networks: \(failed)")
            }
        }
    }
}
