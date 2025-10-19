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

import Foundation

/// Value type that contains the plugin configuration, the parsed name of the
/// plugin and whether a CLI surface for the plugin was found.
public struct Plugin: Sendable, Codable {
    private static let machServicePrefix = "com.apple.container."

    /// Pathname to installation directory for plugins.
    public let binaryURL: URL

    /// Configuration for the plugin.
    public let config: PluginConfig

    public init(binaryURL: URL, config: PluginConfig) {
        self.binaryURL = binaryURL
        self.config = config
    }
}

extension Plugin {
    public var name: String { binaryURL.lastPathComponent }

    public var shouldBoot: Bool {
        guard let config = self.config.servicesConfig else {
            return false
        }

        return config.loadAtBoot
    }

    public func getLaunchdLabel(instanceId: String? = nil) -> String {
        // Use the plugin name for the launchd label.
        guard let instanceId else {
            return "\(Self.machServicePrefix)\(self.name)"
        }
        return "\(Self.machServicePrefix)\(self.name).\(instanceId)"
    }

    public func getMachServices(instanceId: String? = nil) -> [String] {
        // Use the service type for the mach service.
        guard let config = self.config.servicesConfig else {
            return []
        }
        var services = [String]()
        for service in config.services {
            let serviceName: String
            if let instanceId {
                serviceName = "\(Self.machServicePrefix)\(service.type.rawValue).\(name).\(instanceId)"
            } else {
                serviceName = "\(Self.machServicePrefix)\(service.type.rawValue).\(name)"
            }
            services.append(serviceName)
        }
        return services
    }

    public func getMachService(instanceId: String? = nil, type: PluginConfig.DaemonPluginType) -> String? {
        guard hasType(type) else {
            return nil
        }

        guard let instanceId else {
            return "\(Self.machServicePrefix)\(type.rawValue).\(name)"
        }
        return "\(Self.machServicePrefix)\(type.rawValue).\(name).\(instanceId)"
    }

    public func hasType(_ type: PluginConfig.DaemonPluginType) -> Bool {
        guard let config = self.config.servicesConfig else {
            return false
        }

        guard !(config.services.filter { $0.type == type }.isEmpty) else {
            return false
        }

        return true
    }
}

extension Plugin {
    public func exec(args: [String]) throws {
        var args = args
        let executable = self.binaryURL.path
        args[0] = executable
        let argv = args.map { strdup($0) } + [nil]
        guard execvp(executable, argv) != -1 else {
            throw POSIXError.fromErrno()
        }
        fatalError("unreachable")
    }

    func helpText(padding: Int) -> String {
        guard !self.name.isEmpty else {
            return ""
        }
        let namePadded = name.padding(toLength: padding, withPad: " ", startingAt: 0)
        return "  " + namePadded + self.config.abstract
    }
}
