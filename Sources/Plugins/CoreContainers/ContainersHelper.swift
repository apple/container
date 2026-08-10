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
import ContainerAPIClient
import ContainerAPIService
import ContainerLog
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerVersion
import ContainerXPC
import Foundation
import Logging
import SystemPackage

@main
struct ContainersHelper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-core-containers",
        abstract: "XPC service for managing containers and pods",
        version: ReleaseVersion.singleLine(appName: "container-core-containers"),
        subcommands: [
            Start.self
        ]
    )
}

extension ContainersHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Starts the container and pod plugin"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .long, help: "XPC service prefix")
        var serviceIdentifier: String = "com.apple.container.core.container-core-containers"

        var appRoot = ApplicationRoot.path

        var installRoot = InstallRoot.path

        var logRoot = LogRoot.path

        func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
            let commandName = ContainersHelper._commandName
            let logPath = logRoot.map { $0.appending("\(commandName).log") }
            let log = ServiceLogger.bootstrap(category: "ContainersHelper", debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                log.info("configuring XPC server")
                let pluginLoader = try initializePluginLoader(log: log)
                var routes = [String: XPCServer.RouteHandler]()
                let containersService = try initializeContainersService(
                    pluginLoader: pluginLoader,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    routes: &routes
                )
                let podsService = try initializePodsService(
                    pluginLoader: pluginLoader,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    routes: &routes
                )

                let networksService = try await initializeNetworksService(
                    pluginLoader: pluginLoader,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    routes: &routes
                )

                // The three services address each other directly: a container
                // bootstraps by asking its pod to run holding it, a pod forced
                // away takes its containers with it, and both claim addresses
                // from the networks they attach. They share one process so
                // those calls keep their lock conventions.
                await podsService.setContainersService(containersService)
                await containersService.setPodsService(podsService)
                await containersService.setNetworksService(networksService)
                await podsService.setNetworksService(networksService)

                // Machines outlive the process that made them, so before
                // serving, adopt the ones still running: pods dial their
                // launchd services, containers take their machine's word.
                await podsService.reconnect()
                await containersService.reconnect()

                let xpc = XPCServer(
                    identifier: serviceIdentifier,
                    routes: routes,
                    log: log
                )
                log.info("starting XPC server")
                try await xpc.listen()
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ])
                ContainersHelper.exit(withError: error)
            }
        }

        private func initializePluginLoader(log: Logger) throws -> PluginLoader {
            log.info(
                "initializing plugin loader",
                metadata: [
                    "installRoot": "\(installRoot.string)"
                ])

            // TODO: Remove when we convert PluginLoader to FilePath
            let installRootURL = URL(fileURLWithPath: installRoot.string)
            let pluginsURL = PluginLoader.userPluginsDir(installRoot: installRootURL)
            log.info("detecting user plugins directory", metadata: ["path": "\(pluginsURL.path(percentEncoded: false))"])
            var directoryExists: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: pluginsURL.path, isDirectory: &directoryExists)
            let userPluginsURL = directoryExists.boolValue ? pluginsURL : nil

            // plugins built into the application installed as a Unix-like application
            let installRootPluginsPath =
                installRoot
                .appending(FilePath.Component("libexec"))
                .appending(FilePath.Component("container"))
                .appending(FilePath.Component("plugins"))
            let installRootPluginsURL = URL(fileURLWithPath: installRootPluginsPath.string)

            let pluginDirectories = [
                userPluginsURL,
                installRootPluginsURL,
            ].compactMap { $0 }

            let pluginFactories: [PluginFactory] = [
                DefaultPluginFactory(logger: log),
                AppBundlePluginFactory(logger: log),
            ]

            for pluginDirectory in pluginDirectories {
                log.info("discovered plugin directory", metadata: ["path": "\(pluginDirectory.path(percentEncoded: false))"])
            }

            let appRootURL = URL(fileURLWithPath: appRoot.string)
            return try PluginLoader(
                appRoot: appRootURL,
                installRoot: installRootURL,
                logRoot: logRoot,
                pluginDirectories: pluginDirectories,
                pluginFactories: pluginFactories,
                log: log
            )
        }

        private func initializeContainersService(
            pluginLoader: PluginLoader,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger,
            routes: inout [String: XPCServer.RouteHandler]
        ) throws -> ContainersService {
            log.info("initializing containers service")

            // TODO: Remove when we convert ContainersService to FilePath
            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let service = try ContainersService(
                appRoot: appRootURL,
                pluginLoader: pluginLoader,
                containerSystemConfig: containerSystemConfig,
                log: log,
                debugHelpers: debug
            )
            let harness = ContainersHarness(service: service, log: log)

            routes[XPCRoute.containerList.rawValue] = XPCServer.route(harness.list)
            routes[XPCRoute.containerCreate.rawValue] = XPCServer.route(harness.create)
            routes[XPCRoute.containerDelete.rawValue] = XPCServer.route(harness.delete)
            routes[XPCRoute.containerLogs.rawValue] = XPCServer.route(harness.logs)
            routes[XPCRoute.containerBootstrap.rawValue] = XPCServer.route(harness.bootstrap)
            routes[XPCRoute.containerDial.rawValue] = XPCServer.route(harness.dial)
            routes[XPCRoute.containerStop.rawValue] = XPCServer.route(harness.stop)
            routes[XPCRoute.containerStartProcess.rawValue] = XPCServer.route(harness.startProcess)
            routes[XPCRoute.containerCreateProcess.rawValue] = XPCServer.route(harness.createProcess)
            routes[XPCRoute.containerResize.rawValue] = XPCServer.route(harness.resize)
            routes[XPCRoute.containerWait.rawValue] = XPCServer.route(harness.wait)
            routes[XPCRoute.containerKill.rawValue] = XPCServer.route(harness.kill)
            routes[XPCRoute.containerStats.rawValue] = XPCServer.route(harness.stats)
            routes[XPCRoute.containerDiskUsage.rawValue] = XPCServer.route(harness.diskUsage)
            routes[XPCRoute.containerCopyIn.rawValue] = XPCServer.route(harness.copyIn)
            routes[XPCRoute.containerCopyOut.rawValue] = XPCServer.route(harness.copyOut)
            routes[XPCRoute.containerExport.rawValue] = XPCServer.route(harness.export)
            routes[XPCRoute.containerVolumesInUse.rawValue] = XPCServer.route(harness.volumeNamesInUse)
            routes[XPCRoute.containerVolumeReferences.rawValue] = XPCServer.route(harness.volumeReferences)
            routes[XPCRoute.containerNetworkReferences.rawValue] = XPCServer.route(harness.networkReferences)
            routes[XPCRoute.containerImageReferences.rawValue] = XPCServer.route(harness.imageReferences)
            routes[XPCRoute.containerUsageTotals.rawValue] = XPCServer.route(harness.usageTotals)

            return service
        }

        private func initializePodsService(
            pluginLoader: PluginLoader,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger,
            routes: inout [String: XPCServer.RouteHandler]
        ) throws -> PodsService {
            log.info("initializing pods service")

            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let service = try PodsService(
                appRoot: appRootURL,
                pluginLoader: pluginLoader,
                containerSystemConfig: containerSystemConfig,
                debugHelpers: debug,
                log: log
            )
            let harness = PodsHarness(service: service, log: log)

            routes[XPCRoute.podCreate.rawValue] = XPCServer.route(harness.create)
            routes[XPCRoute.podStart.rawValue] = XPCServer.route(harness.start)
            routes[XPCRoute.podStop.rawValue] = XPCServer.route(harness.stop)
            routes[XPCRoute.podDelete.rawValue] = XPCServer.route(harness.delete)
            routes[XPCRoute.podInspect.rawValue] = XPCServer.route(harness.inspect)
            routes[XPCRoute.podList.rawValue] = XPCServer.route(harness.list)
            routes[XPCRoute.podUpdate.rawValue] = XPCServer.route(harness.update)

            return service
        }

        private func initializeNetworksService(
            pluginLoader: PluginLoader,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger,
            routes: inout [String: XPCServer.RouteHandler]
        ) async throws -> NetworksService {
            log.info("initializing networks service")

            let resourceRoot = appRoot.appending(FilePath.Component("networks"))
            let defaultNetworkConfig = try NetworkConfiguration(
                name: NetworkClient.defaultNetworkName,
                mode: .nat,
                ipv4Subnet: containerSystemConfig.network.subnet,
                ipv6Subnet: containerSystemConfig.network.subnetv6,
                labels: try .init([ResourceLabelKeys.role: ResourceRoleValues.builtin]),
                plugin: "container-network-vmnet"
            )
            let service = try await NetworksService(
                pluginLoader: pluginLoader,
                resourceRoot: resourceRoot,
                defaultNetworkConfiguration: defaultNetworkConfig,
                log: log,
                debugHelpers: debug
            )

            let defaultNetwork = try await service.list()
                .filter { $0.isBuiltin }
                .first
            if defaultNetwork == nil {
                // FIXME: default network should be configurable elsewhere
                _ = try await service.create(configuration: defaultNetworkConfig)
            }

            let harness = NetworksHarness(service: service, log: log)

            if #available(macOS 26, *) {
                routes[XPCRoute.networkCreate.rawValue] = XPCServer.route(harness.create)
            }
            routes[XPCRoute.networkList.rawValue] = XPCServer.route(harness.list)
            routes[XPCRoute.networkDelete.rawValue] = XPCServer.route(harness.delete)
            routes[XPCRoute.networkLookup.rawValue] = XPCServer.route(harness.lookup)

            return service
        }
    }
}
