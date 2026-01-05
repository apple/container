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

//
import Foundation

/// PluginConfig details all of the fields to describe and register a plugin.
/// A plugin is registered by creating a subdirectory  `<application-root>/user-plugins`,
/// where the name of the subdirectory is the name of the plugin, and then placing a
/// file named `config.json` inside with the schema below.
/// If `services` is filled in then there MUST be a binary named  matching the plugin name
/// in a `bin` subdirectory inside the same directory as the `config.json`.
/// An example of a valid plugin directory structure would be
/// $ tree foobar
/// foobar
/// ├── bin
/// │   └── foobar
/// └── config.json
public struct PluginConfig: Sendable, Codable {
    /// Categories of services that can be offered through plugins.
    public enum DaemonPluginType: String, Sendable, Codable {
        /// A runtime plugin provides an XPC API through which the lifecycle
        /// of a **single** container can be managed.
        /// A runtime daemon plugin would typically also have a counterpart
        /// CLI plugin which knows how to talk to the API exposed by the runtime plugin.
        /// The API server ensures that a single instance of the plugin is configured
        /// for a given container such that the client can communicate with it given an instance id.
        case runtime
        /// A network plugin provides an XPC API through which IP address allocations on a given
        /// network can be managed. The API server ensures that a single instance
        /// of this plugin is configured for a given network. Similar to the runtime plugin, it typically
        /// would be accompanied by a CLI plugin that knows how to communicate with the XPC API
        /// given an instance id.
        case network
        /// A core plugin provides an XPC API to manage a given type of resource.
        /// The API server ensures that there exist only a single running instance
        /// of this plugin type. A core plugin can be thought of a singleton whose lifecycle
        /// is tied to that of the API server. Core plugins can be used to expand the base functionality
        /// provided by the API server. As with the other plugin types, it maybe associated with a client
        /// side plugin that communicates with the XPC service exposed by the daemon plugin.
        case core
        /// Reserved for future use. Currently there is no difference between a core and auxiliary daemon plugin.
        case auxiliary
    }

    // An XPC service that the plugin publishes.
    public struct Service: Sendable, Codable {
        /// The type of the service the daemon is exposing.
        /// One plugin can expose multiple services of different types.
        ///
        /// The plugin MUST expose a MachService at
        /// `com.apple.container.{type}.{name}.[{id}]` for
        /// each service that it exposes.
        public let type: DaemonPluginType
        /// Optional description of this service.
        public let description: String?
    }

    /// Descriptor for the services that the plugin offers.
    public struct ServicesConfig: Sendable, Codable {
        /// Load the plugin into launchd when the API server starts.
        public let loadAtBoot: Bool
        /// Launch the plugin binary as soon as it loads into launchd.
        public let runAtLoad: Bool
        /// The service types that the plugin provides.
        public let services: [Service]
        /// An optional parameter that include any command line arguments
        /// that must be passed to the plugin binary when it is loaded.
        /// This parameter is used only when `servicesConfig.loadAtBoot` is `true`
        public let defaultArguments: [String]
    }

    /// Short description of the plugin surface. This will be displayed as the
    /// help-text for CLI plugins, and will be returned in API calls to view loaded
    /// plugins from the daemon.
    public let abstract: String

    /// Author of the plugin. This is solely metadata.
    public let author: String?

    /// Services configuration. Specify nil for a CLI plugin, and an empty array for
    /// that does not publish any XPC services.
    public let servicesConfig: ServicesConfig?
}

extension PluginConfig {
    public var isCLI: Bool { self.servicesConfig == nil }
}

extension PluginConfig {
    public init?(configURL: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configURL.path) {
            return nil
        }

        guard let data = fm.contents(atPath: configURL.path) else {
            return nil
        }

        let decoder: JSONDecoder = JSONDecoder()
        self = try decoder.decode(PluginConfig.self, from: data)
    }
}
