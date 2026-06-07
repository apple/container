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
import ContainerNetworkVmnetHelperServer
import ContainerPlugin
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

extension NetworkVmnetHelperPlugin {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Starts the bridged network plugin"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .long, help: "XPC service identifier")
        var serviceIdentifier: String

        @Option(name: .shortAndLong, help: "Network identifier")
        var id: String

        // Bridged networks define their own semantics, so the mode
        // from the API server is accepted and ignored.
        @Option(name: .long, help: "Network mode (ignored)")
        var mode: String = "nat"

        @Option(name: .customLong("subnet"), help: "CIDR address of the physical IPv4 subnet")
        var ipv4Subnet: String?

        @Option(
            name: .customLong("option"),
            help: "Plugin option as key=value (interface=NAME, gateway=ADDR, pool=START-END, helper-path=PATH)"
        )
        var options: [String] = []

        var logRoot = LogRoot.path

        func run() async throws {
            let commandName = NetworkVmnetHelperPlugin._commandName
            let logPath = logRoot.map { $0.appending("\(commandName)-\(id).log") }
            let log = ServiceLogger.bootstrap(category: "NetworkVmnetHelperPlugin", metadata: ["id": "\(id)"], debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                let configuration = try parseConfiguration()
                let network = VmnetHelperPhysicalNetwork(configuration: configuration, log: log)
                try await network.start()
                let service = VmnetHelperNetworkService(network: network, log: log)
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
                NetworkVmnetHelperPlugin.exit(withError: error)
            }
        }

        private func parseConfiguration() throws -> VmnetHelperPhysicalNetwork.Configuration {
            guard let subnetText = ipv4Subnet else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "bridged networks require the physical subnet, create the network with --subnet"
                )
            }
            let subnet = try CIDRv4(subnetText)

            var optionValues: [String: String] = [:]
            for option in options {
                let keyVal = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyVal.count == 2, !keyVal[0].isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "invalid option format '\(option)': expected key=value")
                }
                optionValues[String(keyVal[0])] = String(keyVal[1])
            }

            guard let hostInterface = optionValues[VmnetHelperNetwork.Option.interface.rawValue], !hostInterface.isEmpty else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "bridged networks require the host interface, create the network with --option interface=NAME"
                )
            }
            guard let gatewayText = optionValues[VmnetHelperNetwork.Option.gateway.rawValue] else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "bridged networks require the gateway address, create the network with --option gateway=ADDR"
                )
            }
            let gateway = try IPv4Address(gatewayText)

            var pool: ClosedRange<UInt32>?
            if let poolText = optionValues[VmnetHelperNetwork.Option.pool.rawValue] {
                let bounds = poolText.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2,
                    let lower = try? IPv4Address(String(bounds[0])),
                    let upper = try? IPv4Address(String(bounds[1])),
                    lower.value <= upper.value
                else {
                    throw ContainerizationError(.invalidArgument, message: "invalid pool '\(poolText)': expected START-END IPv4 addresses")
                }
                pool = lower.value...upper.value
            }

            return try VmnetHelperPhysicalNetwork.Configuration(
                id: id,
                ipv4Subnet: subnet,
                ipv4Gateway: gateway,
                hostInterface: hostInterface,
                pool: pool,
                helperPath: optionValues[VmnetHelperNetwork.Option.helperPath.rawValue]
            )
        }
    }
}
