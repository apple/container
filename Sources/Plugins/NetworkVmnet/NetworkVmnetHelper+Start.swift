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
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Darwin
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

        var logRoot = LogRoot.path

        func run() async throws {
            let commandName = NetworkVmnetHelper._commandName
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
                    options: ["variant": self.variant.rawValue]
                )
                let network = try Self.createNetwork(
                    configuration: configuration,
                    variant: self.variant,
                    log: log
                )
                try await network.start()
                // The addresses this network hands out are written down beside
                // the network they belong to, the way a host-local allocator
                // keeps its allocations under a directory of its own.
                // https://cni.dev/plugins/current/ipam/host-local/
                let leases = FilesystemAttachmentLeaseStore(
                    store: try FilesystemEntityStore<AttachmentAllocator.Lease>(
                        path: PathUtils.BaseConfigPath.appRoot.basePath()
                            .appending("networks")
                            .appending(id)
                            .appending("leases"),
                        type: "lease",
                        log: log
                    ),
                    log: log
                )
                let service = try await DefaultNetworkService(network: network, leases: leases, log: log)
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

                // What the network holds is given back when this helper is
                // asked to go away, so the addresses it was given can be
                // handed out again; a helper that exits still holding them
                // leaves the range spoken for by nobody.
                let signals = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM])
                Task {
                    for await _ in signals.signals {
                        log.info("releasing the network before exit")
                        await network.stop()
                        Darwin.exit(0)
                    }
                }

                log.info("starting XPC server")
                do {
                    try await xpc.listen()
                } catch {
                    // Whatever ends the wait, the addresses go back: a helper
                    // that leaves holding them leaves them held by nobody, and
                    // the next network asking for that range is refused with
                    // no interface, route, or process to point at.
                    await network.stop()
                    throw error
                }
                await network.stop()
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
