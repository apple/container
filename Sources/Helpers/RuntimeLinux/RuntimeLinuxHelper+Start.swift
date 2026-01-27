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

import ArgumentParser
import ContainerLog
import ContainerResource
import ContainerSandboxService
import ContainerSandboxServiceClient
import ContainerXPC
import Foundation
import Logging
import NIO

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

        var machServiceLabel: String {
            "\(Self.label).\(uuid)"
        }

        func run() async throws {
            let commandName = Self._commandName
            let log = RuntimeLinuxHelper.setupLogger(debug: debug, metadata: ["uuid": "\(uuid)"])

            log.info("starting \(commandName)")
            defer {
                log.info("stopping \(commandName)")
            }

            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            do {
                try adjustLimits()
                signal(SIGPIPE, SIG_IGN)

                log.info("configuring XPC server")
                let interfaceStrategy: any InterfaceStrategy
                if #available(macOS 26, *) {
                    interfaceStrategy = NonisolatedInterfaceStrategy(log: log)
                } else {
                    interfaceStrategy = IsolatedInterfaceStrategy()
                }

                nonisolated(unsafe) let anonymousConnection = xpc_connection_create(nil, nil)
                let server = SandboxService(
                    root: .init(fileURLWithPath: root),
                    interfaceStrategy: interfaceStrategy,
                    eventLoopGroup: eventLoopGroup,
                    connection: anonymousConnection,
                    log: log
                )

                let endpointServer = XPCServer(
                    identifier: machServiceLabel,
                    routes: [
                        SandboxRoutes.createEndpoint.rawValue: server.createEndpoint
                    ],
                    log: log
                )

                let mainServer = XPCServer(
                    connection: anonymousConnection,
                    routes: [
                        SandboxRoutes.bootstrap.rawValue: server.bootstrap,
                        SandboxRoutes.createProcess.rawValue: server.createProcess,
                        SandboxRoutes.state.rawValue: server.state,
                        SandboxRoutes.stop.rawValue: server.stop,
                        SandboxRoutes.kill.rawValue: server.kill,
                        SandboxRoutes.resize.rawValue: server.resize,
                        SandboxRoutes.wait.rawValue: server.wait,
                        SandboxRoutes.start.rawValue: server.startProcess,
                        SandboxRoutes.dial.rawValue: server.dial,
                        SandboxRoutes.shutdown.rawValue: server.shutdown,
                        SandboxRoutes.statistics.rawValue: server.statistics,
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
                log.error("\(commandName) failed", metadata: ["error": "\(error)"])
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
