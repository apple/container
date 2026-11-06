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
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation

/// A network as `network inspect` prints it: the resource, plus the MTU that a
/// container attaching to it now would get.
struct InspectedNetwork: Encodable {
    let network: NetworkResource
    let effectiveMTU: UInt32

    init(network: NetworkResource, defaultMTU: UInt32) {
        self.network = network
        self.effectiveMTU = network.configuration.mtu ?? defaultMTU
    }

    private enum CodingKeys: String, CodingKey {
        case effectiveMTU
    }

    func encode(to encoder: Encoder) throws {
        try network.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effectiveMTU, forKey: .effectiveMTU)
    }
}

extension Application {
    public struct NetworkInspect: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more networks")

        @Argument(help: "Networks to inspect")
        var networks: [String]

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let networkClient = NetworkClient()
            let uniqueNames = Set(networks)
            let items = try await networkClient.list().filter { uniqueNames.contains($0.id) }

            if items.count != uniqueNames.count {
                let found = Set(items.map { $0.id })
                let missing = uniqueNames.subtracting(found).sorted()
                throw ContainerizationError(
                    .notFound,
                    message: "network not found: \(missing.joined(separator: ", "))"
                )
            }

            let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
            let defaultMTU = try NetworkMTU.resolve(config: containerSystemConfig.network.mtu)
            let inspected = items.map { InspectedNetwork(network: $0, defaultMTU: defaultMTU) }

            try Output.emit(Output.renderJSON(inspected, options: .pretty))
        }
    }
}
