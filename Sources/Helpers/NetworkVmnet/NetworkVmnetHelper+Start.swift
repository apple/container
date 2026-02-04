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
import ContainerNetworkService
import ContainerNetworkServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

enum Variant: String, ExpressibleByArgument {
    case reserved
    case allocationOnly
}

extension NetworkMode: ExpressibleByArgument {}

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

        @Option(name: .long, help: "Network mode")
        var mode: NetworkMode = .nat

        @Option(name: .customLong("subnet"), help: "CIDR address for the IPv4 subnet")
        var ipv4Subnet: String?

        @Option(name: .customLong("subnet-v6"), help: "CIDR address for the IPv6 prefix")
        var ipv6Subnet: String?

        @Option(name: .long, help: "Variant of the network helper to use.")
        var variant: Variant = {
            guard #available(macOS 26, *) else {
                return .allocationOnly
            }
            return .reserved
        }()

        func run() async throws {
            let commandName = NetworkVmnetHelper._commandName
            let log = setupLogger(id: id, debug: debug)
            log.info("starting \(commandName)")
            defer {
                log.info("stopping \(commandName)")
            }

            do {
                log.info("configuring XPC server")
                let ipv4Subnet = try self.ipv4Subnet.map { try CIDRv4($0) }
                let ipv6Subnet = try self.ipv6Subnet.map { try CIDRv6($0) }
                let configuration = try NetworkConfiguration(
                    id: id,
                    mode: mode,
                    ipv4Subnet: ipv4Subnet,
                    ipv6Subnet: ipv6Subnet,
                )
                let network = try Self.createNetwork(
                    configuration: configuration,
                    variant: self.variant,
                    log: log
                )
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

        private static func createNetwork(configuration: NetworkConfiguration, variant: Variant, log: Logger) throws -> Network {
            switch variant {
            case .allocationOnly:
                return try AllocationOnlyVmnetNetwork(configuration: configuration, log: log)
            case .reserved:
                guard #available(macOS 26, *) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "variant ReservedVmnetNetwork is only available on macOS 26+"
                    )
                }
                return try ReservedVmnetNetwork(configuration: configuration, log: log)
            }
        }
    }
}
