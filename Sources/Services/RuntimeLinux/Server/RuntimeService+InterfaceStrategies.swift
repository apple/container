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

import ContainerPlugin
import ContainerRuntimeClient
import Logging

extension RuntimeService {
    /// The interface strategy for each variant that the network services of
    /// `plugins` declare in their manifests, keyed by plugin and variant.
    package static func interfaceStrategies(plugins: [Plugin], log: Logger) -> [NetworkInterfaceKey: InterfaceStrategy] {
        var strategies: [NetworkInterfaceKey: InterfaceStrategy] = [:]
        for plugin in plugins {
            let services = plugin.config.servicesConfig?.services ?? []
            for service in services where service.type == .network {
                for (variant, type) in service.interfaces ?? [:] {
                    let key = NetworkInterfaceKey(plugin: plugin.name, variant: variant)
                    switch type {
                    case .isolated:
                        strategies[key] = IsolatedInterfaceStrategy()
                    case .nonisolated:
                        // The strategy type is gated to macOS 26. A manifest declares its
                        // variants on every system, and a plugin starts its networks with this
                        // one only where the strategy is available, so an earlier system skips
                        // it, and an attachment naming it fails where the table is read.
                        guard #available(macOS 26, *) else {
                            log.debug(
                                "interface strategy unavailable on this OS",
                                metadata: ["plugin": "\(plugin.name)", "variant": "\(variant)", "strategy": "\(type.rawValue)"])
                            continue
                        }
                        strategies[key] = NonisolatedInterfaceStrategy(log: log)
                    }
                }
            }
        }
        return strategies
    }
}
