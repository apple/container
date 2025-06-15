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

import ContainerizationOS
import Foundation
import Logging

public struct PluginLoader: Sendable {
    // A path on disk managed by the PluginLoader, where it stores
    // runtime data for loaded plugins. This includes the launchd plists
    // and logs files.
    private let defaultPluginResourcePath: URL

    private let pluginDirectories: [URL]

    private let pluginFactories: [PluginFactory]

    private let log: Logger?

    public typealias PluginQualifier = ((Plugin) -> Bool)

    public init(pluginDirectories: [URL], pluginFactories: [PluginFactory], defaultResourcePath: URL, log: Logger? = nil) {
        self.pluginDirectories = pluginDirectories
        self.pluginFactories = pluginFactories
        self.log = log
        self.defaultPluginResourcePath = defaultResourcePath
    }

    static public func defaultPluginResourcePath(root: URL) -> URL {
        root.appending(path: "plugin-state")
    }

    static public func userPluginsDir(root: URL) -> URL {
        root.appending(path: "user-plugins")
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
        let footer = String(lines.removeLast())

        let sectionHeader = "PLUGINS:"
        lines.append(sectionHeader)

        for plugin in plugins {
            let helpText = plugin.helpText(padding: 24)
            lines.append(helpText)
        }
        lines.append("")
        lines.append(footer)

        return lines.joined(separator: "\n")
    }

    public func findPlugins() -> [Plugin] {
        let fm = FileManager.default

        var pluginNames = Set<String>()
        var plugins: [Plugin] = []

        for pluginDir in pluginDirectories {
            if !fm.fileExists(atPath: pluginDir.path) {
                continue
            }

            guard
                var dirs = try? fm.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles
                )
            else {
                continue
            }
            dirs = dirs.filter {
                $0.isDirectory
            }

            for installURL in dirs {
                do {
                    guard
                        let plugin = try
                            (pluginFactories.compactMap {
                                try $0.create(installURL: installURL)
                            }.first)
                    else {
                        log?.warning(
                            "Not installing plugin with missing configuration",
                            metadata: [
                                "path": "\(installURL.path)"
                            ]
                        )
                        continue
                    }

                    guard !pluginNames.contains(plugin.name) else {
                        log?.warning(
                            "Not installing shadowed plugin",
                            metadata: [
                                "path": "\(installURL.path)",
                                "name": "\(plugin.name)",
                            ])
                        continue
                    }

                    plugins.append(plugin)
                    pluginNames.insert(plugin.name)
                } catch {
                    log?.warning(
                        "Not installing plugin with invalid configuration",
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

    public func findPlugin(name: String, log: Logger? = nil) -> Plugin? {
        do {
            return
                try pluginDirectories
                .compactMap { installURL in
                    try pluginFactories.compactMap { try $0.create(installURL: installURL.appending(path: name)) }.first
                }
                .first
        } catch {
            log?.warning(
                "Not installing plugin with invalid configuration",
                metadata: [
                    "name": "\(name)",
                    "error": "\(error)",
                ]
            )
            return nil
        }
    }
}

extension PluginLoader {
    public func registerWithLaunchd(
        plugin: Plugin,
        rootURL: URL? = nil,
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
        let rootURL = rootURL ?? self.defaultPluginResourcePath.appending(path: plugin.name)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment.filter { key, _ in
            key.hasPrefix("CONTAINER_")
        }
        let logUrl = rootURL.appendingPathComponent("service.log")
        let plist = LaunchPlist(
            label: id,
            arguments: [plugin.binaryURL.path] + (args ?? serviceConfig.defaultArguments),
            environment: env,
            limitLoadToSessionType: [.Aqua, .Background, .System],
            runAtLoad: serviceConfig.runAtLoad,
            stdout: logUrl.path,
            stderr: logUrl.path,
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
}
