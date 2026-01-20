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

import ContainerizationOS
import Foundation
import Logging

public struct PluginLoader: Sendable {
    private let appRoot: URL

    private let installRoot: URL

    private let pluginDirectories: [URL]

    private let pluginFactories: [PluginFactory]

    private let log: Logger?

    public typealias PluginQualifier = ((Plugin) -> Bool)

    // A path on disk managed by the PluginLoader, where it stores
    // runtime data for loaded plugins. This includes the launchd plists
    // and logs files.
    private let pluginResourceRoot: URL

    public init(
        appRoot: URL,
        installRoot: URL,
        pluginDirectories: [URL],
        pluginFactories: [PluginFactory],
        log: Logger? = nil
    ) throws {
        let pluginResourceRoot = appRoot.appendingPathComponent("plugin-state")
        try FileManager.default.createDirectory(at: pluginResourceRoot, withIntermediateDirectories: true)
        self.pluginResourceRoot = pluginResourceRoot
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.pluginDirectories = pluginDirectories
        self.pluginFactories = pluginFactories
        self.log = log
    }

    static public func userPluginsDir(installRoot: URL) -> URL {
        installRoot
            .appending(path: "libexec")
            .appending(path: "container-plugins")
            .resolvingSymlinksInPath()
    }
}

extension PluginLoader {
    public func alterCLIHelpText(original: String) -> String {
        var plugins = findPlugins()
        plugins = plugins.filter { $0.config.isCLI }
        guard !plugins.isEmpty else {
            return original
        }

        var lines = original.split(separator: "\n").map { String($0) }

        let sectionHeader = "PLUGINS:"
        lines.append(sectionHeader)

        for plugin in plugins {
            let helpText = plugin.helpText(padding: 24)
            lines.append(helpText)
        }

        return lines.joined(separator: "\n")
    }

    /// Scan all plugin directories and detect plugins.
    public func findPlugins() -> [Plugin] {
        let fm = FileManager.default

        // Maintain a set for tracking shadowed plugins
        var pluginNames = Set<String>()
        var plugins: [Plugin] = []

        for pluginDir in pluginDirectories {
            // Skip nonexistent plugin parent directories
            if !fm.fileExists(atPath: pluginDir.path) {
                continue
            }

            // Get all entries under the parent directory
            let resolvedPluginDir = pluginDir.resolvingSymlinksInPath()
            guard
                let urls = try? fm.contentsOfDirectory(
                    at: resolvedPluginDir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: .skipsHiddenFiles
                )
            else {
                continue
            }

            // Filter out all but plugin installation directories
            let installURLs = urls.filter { url in
                if url.isDirectory {
                    return true
                }

                if url.isSymlink {
                    var isDirectory: ObjCBool = false
                    _ = fm.fileExists(atPath: url.resolvingSymlinksInPath().path(percentEncoded: false), isDirectory: &isDirectory)
                    return isDirectory.boolValue
                }

                return false
            }

            for installURL in installURLs {
                do {
                    // Create a plugin with the first factory that can grok the layout under the install URL
                    guard
                        let plugin = try
                            (pluginFactories.compactMap {
                                try $0.create(installURL: installURL)
                            }.first)
                    else {
                        log?.warning(
                            "not installing plugin with missing configuration",
                            metadata: [
                                "path": "\(installURL.path)"
                            ]
                        )
                        continue
                    }

                    // Warn and skip if this plugin name has been encountered already
                    guard !pluginNames.contains(plugin.name) else {
                        log?.warning(
                            "not installing shadowed plugin",
                            metadata: [
                                "path": "\(installURL.path)",
                                "name": "\(plugin.name)",
                            ])
                        continue
                    }

                    // Add the plugin to the list
                    plugins.append(plugin)
                    pluginNames.insert(plugin.name)
                } catch {
                    log?.warning(
                        "not installing plugin with invalid configuration",
                        metadata: [
                            "path": "\(installURL.path)",
                            "error": "\(error)",
                        ]
                    )
                }
            }
        }

        return plugins
    }

    /// Locate a plugin with a specific name.
    public func findPlugin(name: String, log: Logger? = nil) -> Plugin? {
        do {
            for pluginDirectory in pluginDirectories {
                for PluginFactory in pluginFactories {
                    // throw means that the factory is correct but the plugin is broken
                    if let plugin = try PluginFactory.create(parentURL: pluginDirectory, name: name) {
                        return plugin
                    }
                }
            }
        } catch {
            log?.warning(
                "not installing plugin with invalid configuration",
                metadata: [
                    "name": "\(name)",
                    "error": "\(error)",
                ]
            )
        }

        return nil
    }
}

extension PluginLoader {
    public static let proxyKeys = Set([
        "http_proxy", "HTTP_PROXY",
        "https_proxy", "HTTPS_PROXY",
        "no_proxy", "NO_PROXY",
    ])

    public func registerWithLaunchd(
        plugin: Plugin,
        pluginStateRoot: URL? = nil,
        args: [String]? = nil,
        instanceId: String? = nil
    ) throws {
        // We only care about loading plugins that have a service
        // to expose; otherwise, they may just be CLI commands.
        guard let serviceConfig = plugin.config.servicesConfig else {
            return
        }

        let id = plugin.getLaunchdLabel(instanceId: instanceId)
        log?.info("Registering plugin", metadata: ["id": "\(id)"])
        let rootURL = pluginStateRoot ?? self.pluginResourceRoot.appending(path: plugin.name)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var env = Self.filterEnvironment()
        env[ApplicationRoot.environmentName] = appRoot.path(percentEncoded: false)
        env[InstallRoot.environmentName] = installRoot.path(percentEncoded: false)

        let plist = LaunchPlist(
            label: id,
            arguments: [plugin.binaryURL.path] + (args ?? serviceConfig.defaultArguments),
            environment: env,
            limitLoadToSessionType: [.Aqua, .Background, .System],
            runAtLoad: serviceConfig.runAtLoad,
            machServices: plugin.getMachServices(instanceId: instanceId)
        )

        let plistUrl = rootURL.appendingPathComponent("service.plist")
        let data = try plist.encode()
        try data.write(to: plistUrl)
        try ServiceManager.register(plistPath: plistUrl.path)
    }

    public func deregisterWithLaunchd(plugin: Plugin, instanceId: String? = nil) throws {
        // We only care about loading plugins that have a service
        // to expose; otherwise, they may just be CLI commands.
        guard plugin.config.servicesConfig != nil else {
            return
        }
        let domain = try ServiceManager.getDomainString()
        let label = "\(domain)/\(plugin.getLaunchdLabel(instanceId: instanceId))"
        log?.info("Deregistering plugin", metadata: ["id": "\(plugin.getLaunchdLabel())"])
        try ServiceManager.deregister(fullServiceLabel: label)
    }

    public static func filterEnvironment(
        env: [String: String] = ProcessInfo.processInfo.environment,
        additionalAllowKeys: Set<String> = Self.proxyKeys
    ) -> [String: String] {
        env.filter { key, _ in
            key.hasPrefix("CONTAINER_") || additionalAllowKeys.contains(key)
        }
    }
}
