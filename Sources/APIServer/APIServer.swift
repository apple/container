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
import CVersion
import ContainerClient
import ContainerLog
import ContainerNetworkService
import ContainerPlugin
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
        version: releaseVersion()
    )

    @Flag(name: .long, help: "Enable debug logging")
    var debug = false

    @Option(name: .shortAndLong, help: "Daemon root directory")
    var root = Self.appRoot.path

    static let appRoot: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("com.apple.container")
    }()

    func run() async throws {
        let commandName = Self.configuration.commandName ?? "container-apiserver"
        let log = setupLogger()
        log.info("starting \(commandName)")
        defer {
            log.info("stopping \(commandName)")
        }

        do {
            log.info("configuring XPC server")
            let root = URL(filePath: root)
            var routes = [XPCRoute: XPCServer.RouteHandler]()
            let pluginLoader = try initializePluginLoader(log: log)
            try await initializePlugins(pluginLoader: pluginLoader, log: log, routes: &routes)
            try initializeContainerService(root: root, pluginLoader: pluginLoader, log: log, routes: &routes)
            let networkService = try await initializeNetworkService(
                root: root,
                pluginLoader: pluginLoader,
                log: log,
                routes: &routes
            )
            initializeHealthCheckService(log: log, routes: &routes)
            try initializeKernelService(log: log, routes: &routes)

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
        // create user-installed plugins directory if it doesn't exist
        let pluginsURL = PluginLoader.userPluginsDir(root: Self.appRoot)
        try FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)

        // plugins built into the application installed as a macOS app bundle
        let appBundlePluginsURL = Bundle.main.resourceURL?.appending(path: "plugins")

        // plugins built into the application installed as a Unix-like application
        let installRootPluginsURL = CommandLine.executableDirectoryUrl.appendingPathComponent("../libexec/container/plugins")

        let pluginDirectories = [
            pluginsURL,
            appBundlePluginsURL,
            installRootPluginsURL,
        ].compactMap { $0 }

        let pluginFactories: [PluginFactory] = [
            DefaultPluginFactory(),
            AppBundlePluginFactory(),
        ]

        let statePath = PluginLoader.defaultPluginResourcePath(root: Self.appRoot)
        try FileManager.default.createDirectory(at: statePath, withIntermediateDirectories: true)
        return PluginLoader(pluginDirectories: pluginDirectories, pluginFactories: pluginFactories, defaultResourcePath: statePath, log: log)
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
        let svc = HealthCheckHarness(log: log)
        routes[XPCRoute.ping] = svc.ping
    }

    private func initializeKernelService(log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) throws {
        let svc = try KernelService(log: log, appRoot: Self.appRoot)
        let harness = KernelHarness(service: svc, log: log)
        routes[XPCRoute.installKernel] = harness.install
        routes[XPCRoute.getDefaultKernel] = harness.getDefaultKernel
    }

    private func initializeContainerService(root: URL, pluginLoader: PluginLoader, log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) throws {
        let service = try ContainersService(
            root: root,
            pluginLoader: pluginLoader,
            log: log
        )
        let harness = ContainersHarness(service: service, log: log)

        routes[XPCRoute.listContainer] = harness.list
        routes[XPCRoute.createContainer] = harness.create
        routes[XPCRoute.deleteContainer] = harness.delete
        routes[XPCRoute.containerLogs] = harness.logs
        routes[XPCRoute.containerEvent] = harness.eventHandler
    }

    private func initializeNetworkService(
        root: URL,
        pluginLoader: PluginLoader,
        log: Logger,
        routes: inout [XPCRoute: XPCServer.RouteHandler]
    ) async throws -> NetworksService {
        let resourceRoot = root.appendingPathComponent("networks")
        let service = try await NetworksService(
            pluginLoader: pluginLoader,
            resourceRoot: resourceRoot,
            log: log
        )

        let defaultNetwork = try await service.list()
            .filter { $0.id == ClientNetwork.defaultNetworkName }
            .first
        if defaultNetwork == nil {
            let config = NetworkConfiguration(id: ClientNetwork.defaultNetworkName, mode: .nat)
            _ = try await service.create(configuration: config)
        }

        let harness = NetworksHarness(service: service, log: log)

        routes[XPCRoute.networkCreate] = harness.create
        routes[XPCRoute.networkDelete] = harness.delete
        routes[XPCRoute.networkList] = harness.list
        return service
    }

    private static func releaseVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? get_release_version().map { String(cString: $0) } ?? "0.0.0"
    }
}
