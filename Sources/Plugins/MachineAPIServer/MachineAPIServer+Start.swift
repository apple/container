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
import ContainerXPC
import Foundation
import Logging
import MachineAPIClient
import MachineAPIService
import SystemPackage

extension MachineAPIServer {
    struct Start: AsyncParsableCommand {
        private static let commandName = "container-machine-apiserver"
        private static let logFile = FilePath.Component("container-machine-apiserver.log")

        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start helper for the API server"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(help: "Path to the resources directory")
        var resources: String

        var logRoot = LogRoot.path

        var pluginStateRoot: FilePath {
            get throws { try PluginStateRoot(plugin: "machine-apiserver").path }
        }

        func run() async throws {
            let debug = debug || (ProcessInfo.processInfo.environment["CONTAINER_DEBUG"] != nil)

            let logPath = logRoot.map { $0.appending(Self.logFile) }
            let log = ServiceLogger.bootstrap(category: "MachineAPIServer", debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(Self.commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(Self.commandName)"])
            }

            do {
                log.info("configuring XPC server")

                let resourceRoot = FilePath(resources)
                let service = try MachinesService(appRoot: pluginStateRoot, resourceRoot: resourceRoot, log: log)
                let harness = MachinesHarness(service: service)

                let server = XPCServer(
                    identifier: MachineClient.serviceIdentifier,
                    routes: [
                        MachineRoutes.listMachine.rawValue: XPCServer.route(harness.list),
                        MachineRoutes.createMachine.rawValue: XPCServer.route(harness.create),
                        MachineRoutes.deleteMachine.rawValue: XPCServer.route(harness.delete),
                        MachineRoutes.setDefault.rawValue: XPCServer.route(harness.setDefault),
                        MachineRoutes.getDefault.rawValue: XPCServer.route(harness.getDefault),
                        MachineRoutes.bootMachine.rawValue: XPCServer.route(harness.boot),
                        MachineRoutes.stopMachine.rawValue: XPCServer.route(harness.stop),
                        MachineRoutes.inspectMachine.rawValue: XPCServer.route(harness.inspect),
                        MachineRoutes.setConfig.rawValue: XPCServer.route(harness.setConfig),
                        MachineRoutes.logsMachine.rawValue: XPCServer.route(harness.logs),
                    ], log: log)

                log.info("starting XPC server")
                try await server.listen()
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(Self.commandName)",
                        "error": "\(error)",
                    ])
                MachineAPIServer.exit(withError: error)
            }
        }
    }
}
