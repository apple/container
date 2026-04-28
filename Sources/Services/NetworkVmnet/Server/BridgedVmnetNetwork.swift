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

import ContainerNetworkClient
import ContainerNetworkServer
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import Synchronization
import Virtualization
import XPC

public final class BridgedVmnetNetwork: ContainerNetworkServer.Network {
    // FIXME: NetworkPluginStatus requires non-optional ipv4Subnet/ipv4Gateway; use placeholder
    // values until the type is refactored to make them optional.
    private static let placeholderSubnet = try! CIDRv4("0.0.0.0/0")
    private static let placeholderGateway = IPv4Address(0)
    private static let placeholderSubnetv6 = try! CIDRv6("::/0")

    private let log: Logger
    private let configuration: NetworkConfiguration
    private let hostInterface: String
    private let statusMutex: Mutex<NetworkStatus?>
    private let enableTso: Bool?
    private let enableChecksumOffload: Bool?
    private let bufferedPacketCount: Int?

    public init(configuration: NetworkConfiguration, log: Logger) throws {
        // TODO: ignore the network type for now - having both network type and plugin variant is a bit awkward...
        // I imagine this will get resolved later on
        // guard configuration.mode == .bridge else {
        //     throw ContainerizationError(.unsupported, message: "invalid network mode \(configuration.mode)")
        // }
        guard let variantStr = configuration.options["variant"],
            let variant = NetworkVariant(rawValue: variantStr),
            variant == .bridged || variant == .bridgedViaHelper
        else {
            throw ContainerizationError(
                .unsupported,
                message: "invalid network variant \(configuration.options["variant"] ?? "unspecified")")
        }

        guard let hostInterface = configuration.options["hostInterface"] else {
            throw ContainerizationError(.invalidArgument, message: "hostInterface must be given as a plugin option")
        }
        let available = VZBridgedNetworkInterface.networkInterfaces.map { $0.identifier }
        guard available.contains(hostInterface) else {
            let list = available.isEmpty ? "none available" : available.joined(separator: ", ")
            throw ContainerizationError(.invalidArgument, message: "no host interface '\(hostInterface)'; available: \(list)")
        }
        self.hostInterface = hostInterface

        self.configuration = configuration
        self.log = log
        self.statusMutex = Mutex(nil)

        if variant == .bridged {
            self.enableTso = nil
            self.enableChecksumOffload = nil
            self.bufferedPacketCount = nil
        } else {
            let rawEnableTso = configuration.options[BridgeNetworkKeys.enableTso.rawValue]
            if rawEnableTso != nil {
                guard let enableTso = Bool(rawEnableTso!) else {
                    throw ContainerizationError(.invalidArgument, message: "enableTso must be a boolean")
                }
                self.enableTso = enableTso
            } else {
                self.enableTso = nil
            }

            let rawEnableChecksumOffload: String? = configuration.options[BridgeNetworkKeys.enableChecksumOffload.rawValue]
            if rawEnableChecksumOffload != nil {
                guard let enableChecksumOffload = Bool(rawEnableChecksumOffload!) else {
                    throw ContainerizationError(.invalidArgument, message: "enableChecksumOffload must be a boolean")
                }
                self.enableChecksumOffload = enableChecksumOffload
            } else {
                self.enableChecksumOffload = nil
            }

            let rawBufferedPacketCount = configuration.options[BridgeNetworkKeys.bufferedPacketCount.rawValue]
            if rawBufferedPacketCount != nil {
                guard let bufferedPacketCount = Int(rawBufferedPacketCount!), bufferedPacketCount > 0 else {
                    throw ContainerizationError(.invalidArgument, message: "bufferedPacketCount must be a positive integer")
                }
                self.bufferedPacketCount = bufferedPacketCount
            } else {
                self.bufferedPacketCount = nil
            }
        }
    }

    public nonisolated var id: String { configuration.id }

    public var status: NetworkStatus? {
        self.statusMutex.withLock { $0 }
    }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        let bridgeConfigMsg = XPCMessage(object: xpc_dictionary_create_empty())
        bridgeConfigMsg.set(key: BridgeNetworkKeys.hostInterface.rawValue, value: hostInterface)
        if self.enableTso != nil {
            bridgeConfigMsg.set(key: BridgeNetworkKeys.enableTso.rawValue, value: self.enableTso!)
        }
        if self.enableChecksumOffload != nil {
            bridgeConfigMsg.set(key: BridgeNetworkKeys.enableChecksumOffload.rawValue, value: self.enableChecksumOffload!)
        }
        if self.bufferedPacketCount != nil {
            bridgeConfigMsg.set(key: BridgeNetworkKeys.bufferedPacketCount.rawValue, value: UInt64(self.bufferedPacketCount!))
        }

        let msg: XPCMessage = XPCMessage(object: xpc_dictionary_create_empty())
        msg.set(key: NetworkKeys.additionalData.rawValue, value: bridgeConfigMsg.underlying)
        try handler(msg)
    }

    public func start() async throws {
        try statusMutex.withLock { status in

            guard status == nil else {
                throw ContainerizationError(.invalidArgument, message: "cannot start network \(configuration.id): already started")
            }

            status = NetworkStatus(
                ipv4Subnet: Self.placeholderSubnet, ipv4Gateway: Self.placeholderGateway, ipv6Subnet: Self.placeholderSubnetv6
            )

            log.info(
                "started bridged network",
                metadata: [
                    "id": "\(configuration.id)",
                    "hostInterface": "\(hostInterface)",
                ]
            )
        }
    }
}
