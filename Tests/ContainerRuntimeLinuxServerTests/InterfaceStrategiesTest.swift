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

import ContainerRuntimeClient
import ContainerRuntimeLinuxServer
import Foundation
import Logging
import Testing

@testable import ContainerPlugin

struct InterfaceStrategiesTest {
    private let log = Logger(label: "InterfaceStrategiesTest")

    private func plugin(_ name: String, services: [PluginConfig.Service]) -> Plugin {
        Plugin(
            binaryURL: URL(filePath: "/plugins/\(name)/bin/\(name)"),
            config: PluginConfig(
                abstract: name,
                author: nil,
                servicesConfig: .init(loadAtBoot: false, runAtLoad: true, services: services, defaultArguments: [])
            )
        )
    }

    @Test
    func testNetworkVariantsMapToTheirStrategies() {
        let plugins = [
            plugin(
                "container-network-vmnet",
                services: [
                    .init(type: .network, description: nil, interfaces: ["allocationOnly": .isolated, "reserved": .nonisolated])
                ])
        ]

        let strategies = RuntimeService.interfaceStrategies(plugins: plugins, log: log)

        let isolated = NetworkInterfaceKey(plugin: "container-network-vmnet", variant: "allocationOnly")
        let nonisolated = NetworkInterfaceKey(plugin: "container-network-vmnet", variant: "reserved")
        #expect(strategies[isolated] is IsolatedInterfaceStrategy)
        if #available(macOS 26, *) {
            #expect(strategies[nonisolated] is NonisolatedInterfaceStrategy)
            #expect(strategies.count == 2)
        } else {
            #expect(strategies[nonisolated] == nil)
            #expect(strategies.count == 1)
        }
    }

    @Test
    func testOnlyNetworkServicesDeclareStrategies() {
        let plugins = [
            plugin(
                "container-runtime-linux",
                services: [.init(type: .runtime, description: nil, interfaces: ["allocationOnly": .isolated])]),
            plugin("container-network-plain", services: [.init(type: .network, description: nil, interfaces: nil)]),
            plugin("container-network-declared", services: [.init(type: .network, description: nil, interfaces: ["shared": .isolated])]),
        ]

        let strategies = RuntimeService.interfaceStrategies(plugins: plugins, log: log)

        #expect(Array(strategies.keys) == [NetworkInterfaceKey(plugin: "container-network-declared", variant: "shared")])
    }
}
