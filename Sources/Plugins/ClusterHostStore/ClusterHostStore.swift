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
import ContainerCluster
import ContainerLog
import ContainerPersistence
import ContainerPlugin
import ContainerVersion
import Foundation
import SystemPackage

@main
struct ClusterHostStore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cluster-hoststore",
        abstract: "Serves host images to container cluster nodes",
        version: ReleaseVersion.singleLine(appName: "cluster-hoststore"),
        subcommands: [Start.self],
    )
}

extension ClusterHostStore {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start the host store server"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        var logRoot = LogRoot.path

        func run() async throws {
            let debug = debug || (ProcessInfo.processInfo.environment["CONTAINER_DEBUG"] != nil)
            let logPath = logRoot.map { $0.appending("cluster-hoststore.log") }
            let log = ServiceLogger.bootstrap(category: "ClusterHostStore", debug: debug, logPath: logPath)

            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
            let socketPath = ClusterHelper.hostStoreSocketPath.string
            let server = HostStoreServer(containerSystemConfig: containerSystemConfig, log: log)
            log.info("serving host store", metadata: ["socket": "\(socketPath)"])
            do {
                try await server.run(socketPath: socketPath)
            } catch {
                log.error("host store failed", metadata: ["error": "\(error)"])
                ClusterHostStore.exit(withError: error)
            }
        }
    }
}
