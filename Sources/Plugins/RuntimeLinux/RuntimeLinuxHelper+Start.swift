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

import ArgumentParser
import ContainerLog
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import ContainerRuntimeLinuxServer
import ContainerXPC
import Foundation
import Logging
import NIO
import SystemPackage

extension RuntimeLinuxHelper {
    struct Start: AsyncParsableCommand {
        static let label = "com.apple.container.runtime.container-runtime-linux"

        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start helper for a Linux container"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .shortAndLong, help: "Sandbox UUID")
        var uuid: String

        @Option(name: .shortAndLong, help: "Root directory for the sandbox")
        var root: String

        var logRoot = LogRoot.path

        var machServiceLabel: String {
            "\(Self.label).\(uuid)"
        }

        /// Build the interface-strategy table from the network plugins present.
        /// Each network plugin declares, in its config.toml, the strategy each of
        /// its interface variants needs; the runtime maps the declared name to a
        /// strategy here, so the supported plugins and variants are the ones
        /// installed rather than a list hardcoded in the runtime. A plugin offers
        /// a variant (say the macOS 26 "reserved" one) only where it is available,
        /// so the OS gate lives with the plugin, not repeated here.
        private func interfaceStrategies(log: Logger) throws -> [NetworkInterfaceKey: InterfaceStrategy] {
            let installRootURL = URL(fileURLWithPath: InstallRoot.path.string)
            let appRootURL = URL(fileURLWithPath: ApplicationRoot.path.string)
            let installPluginsURL =
                installRootURL
                .appendingPathComponent("libexec")
                .appendingPathComponent("container")
                .appendingPathComponent("plugins")
            var pluginDirectories = [installPluginsURL]
            let userPluginsURL = PluginLoader.userPluginsDir(installRoot: installRootURL)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: userPluginsURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                pluginDirectories.insert(userPluginsURL, at: 0)
            }
            let loader = try PluginLoader(
                appRoot: appRootURL,
                installRoot: installRootURL,
                logRoot: logRoot,
                pluginDirectories: pluginDirectories,
                pluginFactories: [DefaultPluginFactory(logger: log), AppBundlePluginFactory(logger: log)],
                log: log
            )

            var strategies: [NetworkInterfaceKey: InterfaceStrategy] = [:]
            for plugin in loader.findPlugins() {
                let services = plugin.config.servicesConfig?.services ?? []
                for service in services where service.type == .network {
                    for (variant, name) in service.interfaces ?? [:] {
                        let strategy: InterfaceStrategy
                        switch name {
                        case "isolated":
                            strategy = IsolatedInterfaceStrategy()
                        case "nonisolated":
                            // The strategy type itself is gated to macOS 26, so the OS
                            // check lives here on the type, not on the plugin list. A
                            // plugin only offers this variant where it is available, so
                            // an older OS simply never asks for it.
                            guard #available(macOS 26, *) else {
                                log.error(
                                    "interface strategy unavailable on this OS",
                                    metadata: ["plugin": "\(plugin.name)", "variant": "\(variant)", "strategy": "\(name)"])
                                continue
                            }
                            strategy = NonisolatedInterfaceStrategy(log: log)
                        default:
                            log.error(
                                "ignoring unknown interface strategy",
                                metadata: ["plugin": "\(plugin.name)", "variant": "\(variant)", "strategy": "\(name)"])
                            continue
                        }
                        strategies[NetworkInterfaceKey(plugin: plugin.name, variant: variant)] = strategy
                    }
                }
            }
            return strategies
        }

        func run() async throws {
            let commandName = RuntimeLinuxHelper._commandName
            let logPath = logRoot.map { $0.appending("\(commandName)-\(uuid).log") }
            let log = ServiceLogger.bootstrap(category: "RuntimeLinuxHelper", metadata: ["uuid": "\(uuid)"], debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            do {
                try adjustLimits()
                signal(SIGPIPE, SIG_IGN)

                // Each network plugin declares in its config.toml the strategy each
                // of its interface variants needs; the runtime builds its table from
                // the plugins present rather than hardcoding them here.
                let interfaceStrategies = try self.interfaceStrategies(log: log)

                log.info("configuring XPC server")
                nonisolated(unsafe) let anonymousConnection = xpc_connection_create(nil, nil)

                let server = RuntimeService(
                    root: .init(fileURLWithPath: root),
                    interfaceStrategies: interfaceStrategies,
                    eventLoopGroup: eventLoopGroup,
                    connection: anonymousConnection,
                    log: log
                )

                let endpointServer = XPCServer(
                    identifier: machServiceLabel,
                    routes: [
                        RuntimeRoutes.createEndpoint.rawValue: XPCServer.route(server.createEndpoint)
                    ],
                    log: log
                )

                let mainServer = XPCServer(
                    connection: anonymousConnection,
                    routes: [
                        RuntimeRoutes.bootstrap.rawValue: XPCServer.route(server.bootstrap),
                        RuntimeRoutes.createProcess.rawValue: XPCServer.route(server.createProcess),
                        RuntimeRoutes.state.rawValue: XPCServer.route(server.state),
                        RuntimeRoutes.stop.rawValue: XPCServer.route(server.stop),
                        RuntimeRoutes.kill.rawValue: XPCServer.route(server.kill),
                        RuntimeRoutes.resize.rawValue: XPCServer.route(server.resize),
                        RuntimeRoutes.wait.rawValue: XPCServer.route(server.wait),
                        RuntimeRoutes.start.rawValue: XPCServer.route(server.startProcess),
                        RuntimeRoutes.dial.rawValue: XPCServer.route(server.dial),
                        RuntimeRoutes.shutdown.rawValue: XPCServer.route(server.shutdown),
                        RuntimeRoutes.statistics.rawValue: XPCServer.route(server.statistics),
                        RuntimeRoutes.copyIn.rawValue: XPCServer.route(server.copyIn),
                        RuntimeRoutes.copyOut.rawValue: XPCServer.route(server.copyOut),
                        RuntimeRoutes.snapshotDisk.rawValue: XPCServer.route(server.snapshotDisk),
                    ],
                    log: log
                )

                log.info("starting XPC server")
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await endpointServer.listen()
                    }
                    group.addTask {
                        try await mainServer.listen()
                    }
                    defer { group.cancelAll() }

                    _ = try await group.next()
                }
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ])
                try? await eventLoopGroup.shutdownGracefully()
                RuntimeLinuxHelper.Start.exit(withError: error)
            }
        }

        private func adjustLimits() throws {
            var limits = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
                throw POSIXError(.init(rawValue: errno)!)
            }
            limits.rlim_cur = 65536
            limits.rlim_max = 65536
            guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
                throw POSIXError(.init(rawValue: errno)!)
            }
        }
    }
}
