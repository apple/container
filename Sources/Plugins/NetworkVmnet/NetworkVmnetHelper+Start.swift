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
import ContainerNetworkClient
import ContainerNetworkServer
import ContainerNetworkVmnetServer
import ContainerPlugin
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

extension NetworkMode: ExpressibleByArgument {}
extension NetworkVariant: ExpressibleByArgument {}

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
        var variant: NetworkVariant = {
            guard #available(macOS 26, *) else {
                return .allocationOnly
            }
            return .reserved
        }()

        @Option(name: .customLong("option-json"), help: "UTF8-encoded JSON string that contains the configuration options for this network")
        var stringifiedOptions: String = "{}"

        var logRoot = LogRoot.path

        func run() async throws {
            let commandName = NetworkVmnetHelper._commandName
            guard let encodedOptions = stringifiedOptions.data(using: .utf8),
                let options = try? JSONSerialization.jsonObject(with: encodedOptions) as? [String: String]
            else {
                throw ContainerizationError(.invalidArgument, message: "failed to decode network configuration options from JSON string")
            }

            let logPath = logRoot.map { $0.appending("\(commandName)-\(id).log") }
            let log = ServiceLogger.bootstrap(category: "NetworkVmnetHelper", metadata: ["id": "\(id)"], debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                log.info("configuring XPC server")
                let ipv4Subnet = try self.ipv4Subnet.map { try CIDRv4($0) }
                let ipv6Subnet = try self.ipv6Subnet.map { try CIDRv6($0) }

                let configuration = try NetworkConfiguration(
                    name: id,
                    mode: mode,
                    ipv4Subnet: ipv4Subnet,
                    ipv6Subnet: ipv6Subnet,
                    plugin: NetworkVmnetHelper._commandName,
                    options: options.merging(
                        ["variant": self.variant.rawValue],
                        uniquingKeysWith: { _, new in new })
                )
                let network = try Self.createNetwork(
                    configuration: configuration,
                    variant: self.variant,
                    log: log
                )
                try await network.start()
                let service = try await DefaultNetworkService(network: network, log: log)
                let harness = NetworkHarness(service: service)
                let xpc = XPCServer(
                    identifier: serviceIdentifier,
                    routes: [
                        NetworkRoutes.status.rawValue: XPCServer.route(harness.status),
                        NetworkRoutes.allocate.rawValue: harness.allocate,
                        NetworkRoutes.lookup.rawValue: XPCServer.route(harness.lookup),
                    ],
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
                NetworkVmnetHelper.exit(withError: error)
            }
        }

        private static func createNetwork(configuration: NetworkConfiguration, variant: NetworkVariant, log: Logger) throws -> Network {
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
            case .bridged, .bridgedViaHelper:
                return try BridgedVmnetNetwork(configuration: configuration, log: log)
            }
        }
    }
}
