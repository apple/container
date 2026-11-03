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
import ContainerClusterService
import ContainerClusterServiceClient
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
struct ClustersHelper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-core-clusters",
        abstract: "XPC service for managing local Kubernetes cluster records",
        version: ReleaseVersion.singleLine(appName: "container-core-clusters"),
        subcommands: [
            Start.self
        ]
    )
}

extension ClustersHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Starts the cluster plugin"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .long, help: "XPC service prefix")
        var serviceIdentifier: String = ClusterClient.serviceIdentifier

        var logRoot = LogRoot.path

        func run() async throws {
            let commandName = ClustersHelper._commandName
            let logPath = logRoot.map { $0.appending("\(commandName).log") }
            let log = ServiceLogger.bootstrap(category: "ClustersHelper", debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                log.info("configuring XPC server")
                let stateRoot = try PluginStateRoot(plugin: commandName).path
                let rootURL = URL(fileURLWithPath: stateRoot.string)
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

                // "cluster" is the label value the cluster CLI plugin (ClusterHelper.pluginName)
                // stamps on its containers; this executable cannot depend on ContainerCluster.
                let listContainers: ClusterService.ContainerLister = {
                    try await ContainerClient().list(
                        filters: ContainerListFilters(labels: [ResourceLabelKeys.plugin: "cluster"]))
                }
                let service = ClusterService(root: rootURL, listContainers: listContainers, log: log)
                let harness = ClusterServiceHarness(service: service, log: log)

                var routes = [String: XPCServer.RouteHandler]()
                routes[ClusterServiceXPCRoute.clusterCreate.rawValue] = XPCServer.route(harness.create)
                routes[ClusterServiceXPCRoute.clusterGet.rawValue] = XPCServer.route(harness.get)
                routes[ClusterServiceXPCRoute.clusterList.rawValue] = XPCServer.route(harness.list)
                routes[ClusterServiceXPCRoute.clusterDelete.rawValue] = XPCServer.route(harness.delete)

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
                ClustersHelper.exit(withError: error)
            }
        }
    }
}
