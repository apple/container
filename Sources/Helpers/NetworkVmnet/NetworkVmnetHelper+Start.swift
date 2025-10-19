//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import ContainerNetworkService
import ContainerXPC
import ContainerizationExtras
import Foundation
import Logging

extension NetworkVmnetHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Starts the network plugin"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .long, help: "XPC service identifier")
        var serviceIdentifier: String

        @Option(name: .shortAndLong, help: "Network identifier")
        var id: String

        @Option(name: .shortAndLong, help: "CIDR address for the subnet")
        var subnet: String?

        func run() async throws {
            let commandName = NetworkVmnetHelper._commandName
            let log = setupLogger(id: id, debug: debug)
            log.info("starting \(commandName)")
            defer {
                log.info("stopping \(commandName)")
            }

            do {
                log.info("configuring XPC server")
                let subnet = try self.subnet.map { try CIDRAddress($0) }
                let configuration = try NetworkConfiguration(id: id, mode: .nat, subnet: subnet?.description)
                let network = try Self.createNetwork(configuration: configuration, log: log)
                try await network.start()
                let server = try await NetworkService(network: network, log: log)
                let xpc = XPCServer(
                    identifier: serviceIdentifier,
                    routes: [
                        NetworkRoutes.state.rawValue: server.state,
                        NetworkRoutes.allocate.rawValue: server.allocate,
                        NetworkRoutes.deallocate.rawValue: server.deallocate,
                        NetworkRoutes.lookup.rawValue: server.lookup,
                        NetworkRoutes.disableAllocator.rawValue: server.disableAllocator,
                    ],
                    log: log
                )

                log.info("starting XPC server")
                try await xpc.listen()
            } catch {
                log.error("\(commandName) failed", metadata: ["error": "\(error)"])
                NetworkVmnetHelper.exit(withError: error)
            }
        }

        private static func createNetwork(configuration: NetworkConfiguration, log: Logger) throws -> Network {
            guard #available(macOS 26, *) else {
                return try AllocationOnlyVmnetNetwork(configuration: configuration, log: log)
            }

            return try ReservedVmnetNetwork(configuration: configuration, log: log)
        }
    }
}
