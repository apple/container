//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import Foundation
import Logging

public actor PluginsService {
    private let log: Logger
    private var loaded: [String: Plugin]
    private let pluginLoader: PluginLoader

    public init(pluginLoader: PluginLoader, log: Logger) {
        self.log = log
        self.loaded = [:]
        self.pluginLoader = pluginLoader
    }

    /// Load the specified plugins, or all plugins with services defined
    /// if none are explicitly specified.
    public func loadAll(
        _ plugins: [Plugin]? = nil,
    ) throws {
        let registerPlugins = plugins ?? pluginLoader.findPlugins()
        for plugin in registerPlugins {
            try pluginLoader.registerWithLaunchd(plugin: plugin)
            loaded[plugin.name] = plugin
        }
    }

    /// Stop the specified plugins, or all plugins with services defined
    /// if none are explicitly specified.
    public func stopAll(_ plugins: [Plugin]? = nil) throws {
        let deregisterPlugins = plugins ?? pluginLoader.findPlugins()
        for plugin in deregisterPlugins {
            try pluginLoader.deregisterWithLaunchd(plugin: plugin)
            self.loaded.removeValue(forKey: plugin.name)
        }
    }

    // MARK: XPC API surface.

    /// Load a single plugin, doing nothing if the plugin is already loaded.
    public func load(name: String) throws {
        guard self.loaded[name] == nil else {
            return
        }
        guard let plugin = pluginLoader.findPlugin(name: name) else {
            throw Error.pluginNotFound(name)
        }
        try pluginLoader.registerWithLaunchd(plugin: plugin)
        self.loaded[plugin.name] = plugin
    }

    /// Get information for a loaded plugin.
    public func get(name: String) throws -> Plugin {
        guard let plugin = loaded[name] else {
            throw Error.pluginNotLoaded(name)
        }
        return plugin
    }

    /// Restart a loaded plugin.
    public func restart(name: String) throws {
        guard let plugin = self.loaded[name] else {
            throw Error.pluginNotLoaded(name)
        }
        try ServiceManager.kickstart(fullServiceLabel: plugin.getLaunchdLabel())
    }

    /// Unload a loaded plugin.
    public func unload(name: String) throws {
        guard let plugin = self.loaded[name] else {
            throw Error.pluginNotLoaded(name)
        }
        try pluginLoader.deregisterWithLaunchd(plugin: plugin)
        self.loaded.removeValue(forKey: plugin.name)
    }

    /// List all loaded plugins.
    public func list() throws -> [Plugin] {
        self.loaded.map { $0.value }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case pluginNotFound(String)
        case pluginNotLoaded(String)

        public var description: String {
            switch self {
            case .pluginNotFound(let name):
                return "plugin not found: \(name)"
            case .pluginNotLoaded(let name):
                return "plugin not loaded: \(name)"
            }
        }
    }
}
