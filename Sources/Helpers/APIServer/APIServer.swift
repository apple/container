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

import ArgumentParser
import ContainerAPIService
import ContainerClient
import ContainerLog
import ContainerNetworkService
import ContainerPlugin
import ContainerVersion
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import DNSServer
import Foundation
import Logging

@main
struct APIServer: AsyncParsableCommand {
    static let listenAddress = "127.0.0.1"
    static let dnsPort = 2053

    static let configuration = CommandConfiguration(
        commandName: "container-apiserver",
        abstract: "Container management API server",
        version: ReleaseVersion.singleLine(appName: "container-apiserver")
    )

    @Flag(name: .long, help: "Enable debug logging")
    var debug = false

    var appRoot = ApplicationRoot.url

    var installRoot = InstallRoot.url

    func run() async throws {
        let commandName = Self.configuration.commandName ?? "container-apiserver"
        let log = setupLogger()
        log.info("starting \(commandName)")
        defer {
            log.info("stopping \(commandName)")
        }

        do {
            log.info("configuring XPC server")
            var routes = [XPCRoute: XPCServer.RouteHandler]()
            let pluginLoader = try initializePluginLoader(log: log)
            try await initializePlugins(pluginLoader: pluginLoader, log: log, routes: &routes)
            let containersService = try initializeContainerService(pluginLoader: pluginLoader, log: log, routes: &routes)
            let networkService = try await initializeNetworkService(
                pluginLoader: pluginLoader,
                containersService: containersService,
                log: log,
                routes: &routes
            )
            initializeHealthCheckService(log: log, routes: &routes)
            try initializeKernelService(log: log, routes: &routes)
            try initializeVolumeService(containersService: containersService, log: log, routes: &routes)

            let server = XPCServer(
                identifier: "com.apple.container.apiserver",
                routes: routes.reduce(
                    into: [String: XPCServer.RouteHandler](),
                    {
                        $0[$1.key.rawValue] = $1.value
                    }), log: log)

            await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    log.info("starting XPC server")
                    try await server.listen()
                }
                // start up host table DNS
                group.addTask {
                    let hostsResolver = ContainerDNSHandler(networkService: networkService)
                    let nxDomainResolver = NxDomainResolver()
                    let compositeResolver = CompositeResolver(handlers: [hostsResolver, nxDomainResolver])
                    let hostsQueryValidator = StandardQueryValidator(handler: compositeResolver)
                    let dnsServer: DNSServer = DNSServer(handler: hostsQueryValidator, log: log)
                    log.info(
                        "starting DNS host query resolver",
                        metadata: [
                            "host": "\(Self.listenAddress)",
                            "port": "\(Self.dnsPort)",
                        ]
                    )
                    try await dnsServer.run(host: Self.listenAddress, port: Self.dnsPort)
                }
            }
        } catch {
            log.error("\(commandName) failed", metadata: ["error": "\(error)"])
            APIServer.exit(withError: error)
        }
    }

    private func setupLogger() -> Logger {
        LoggingSystem.bootstrap { label in
            OSLogHandler(
                label: label,
                category: "APIServer"
            )
        }
        var log = Logger(label: "com.apple.container")
        if debug {
            log.logLevel = .debug
        }
        return log
    }

    private func initializePluginLoader(log: Logger) throws -> PluginLoader {
        log.info(
            "initializing plugin loader",
            metadata: [
                "installRoot": "\(installRoot.path(percentEncoded: false))"
            ])

        let pluginsURL = PluginLoader.userPluginsDir(installRoot: installRoot)
        log.info("detecting user plugins directory", metadata: ["path": "\(pluginsURL.path(percentEncoded: false))"])
        var directoryExists: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: pluginsURL.path, isDirectory: &directoryExists)
        let userPluginsURL = directoryExists.boolValue ? pluginsURL : nil

        // plugins built into the application installed as a macOS app bundle
        let appBundlePluginsURL = Bundle.main.resourceURL?.appending(path: "plugins")

        // plugins built into the application installed as a Unix-like application
        let installRootPluginsURL =
            installRoot
            .appendingPathComponent("libexec")
            .appendingPathComponent("container")
            .appendingPathComponent("plugins")
            .standardized

        let pluginDirectories = [
            userPluginsURL,
            appBundlePluginsURL,
            installRootPluginsURL,
        ].compactMap { $0 }

        let pluginFactories: [PluginFactory] = [
            DefaultPluginFactory(),
            AppBundlePluginFactory(),
        ]

        for pluginDirectory in pluginDirectories {
            log.info("discovered plugin directory", metadata: ["path": "\(pluginDirectory.path(percentEncoded: false))"])
        }

        return try PluginLoader(
            appRoot: appRoot,
            installRoot: installRoot,
            pluginDirectories: pluginDirectories,
            pluginFactories: pluginFactories,
            log: log
        )
    }

    // First load all of the plugins we can find. Then just expose
    // the handlers for clients to do whatever they want.
    private func initializePlugins(
        pluginLoader: PluginLoader,
        log: Logger,
        routes: inout [XPCRoute: XPCServer.RouteHandler]
    ) async throws {
        let bootPlugins = pluginLoader.findPlugins().filter { $0.shouldBoot }

        let service = PluginsService(pluginLoader: pluginLoader, log: log)
        try await service.loadAll(bootPlugins)

        let harness = PluginsHarness(service: service, log: log)
        routes[XPCRoute.pluginGet] = harness.get
        routes[XPCRoute.pluginList] = harness.list
        routes[XPCRoute.pluginLoad] = harness.load
        routes[XPCRoute.pluginUnload] = harness.unload
        routes[XPCRoute.pluginRestart] = harness.restart
    }

    private func initializeHealthCheckService(log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) {
        let svc = HealthCheckHarness(appRoot: appRoot, installRoot: installRoot, log: log)
        routes[XPCRoute.ping] = svc.ping
    }

    private func initializeKernelService(log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) throws {
        let svc = try KernelService(log: log, appRoot: appRoot)
        let harness = KernelHarness(service: svc, log: log)
        routes[XPCRoute.installKernel] = harness.install
        routes[XPCRoute.getDefaultKernel] = harness.getDefaultKernel
    }

    private func initializeContainerService(pluginLoader: PluginLoader, log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) throws -> ContainersService {
        let service = try ContainersService(
            appRoot: appRoot,
            pluginLoader: pluginLoader,
            log: log
        )
        let harness = ContainersHarness(service: service, log: log)

        routes[XPCRoute.listContainer] = harness.list
        routes[XPCRoute.createContainer] = harness.create
        routes[XPCRoute.deleteContainer] = harness.delete
        routes[XPCRoute.containerLogs] = harness.logs
        routes[XPCRoute.containerEvent] = harness.eventHandler

        return service
    }

    private func initializeNetworkService(
        pluginLoader: PluginLoader,
        containersService: ContainersService,
        log: Logger,
        routes: inout [XPCRoute: XPCServer.RouteHandler]
    ) async throws -> NetworksService {
        let resourceRoot = appRoot.appendingPathComponent("networks")
        let service = try await NetworksService(
            pluginLoader: pluginLoader,
            resourceRoot: resourceRoot,
            containersService: containersService,
            log: log
        )

        let defaultNetwork = try await service.list()
            .filter { $0.id == ClientNetwork.defaultNetworkName }
            .first
        if defaultNetwork == nil {
            let config = try NetworkConfiguration(id: ClientNetwork.defaultNetworkName, mode: .nat)
            _ = try await service.create(configuration: config)
        }

        let harness = NetworksHarness(service: service, log: log)

        routes[XPCRoute.networkCreate] = harness.create
        routes[XPCRoute.networkDelete] = harness.delete
        routes[XPCRoute.networkList] = harness.list
        return service
    }

    private func initializeVolumeService(containersService: ContainersService, log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) throws {
        let resourceRoot = appRoot.appendingPathComponent("volumes")
        let service = try VolumesService(resourceRoot: resourceRoot, containersService: containersService, log: log)
        let harness = VolumesHarness(service: service, log: log)

        routes[XPCRoute.volumeCreate] = harness.create
        routes[XPCRoute.volumeDelete] = harness.delete
        routes[XPCRoute.volumeList] = harness.list
        routes[XPCRoute.volumeInspect] = harness.inspect
    }
}
