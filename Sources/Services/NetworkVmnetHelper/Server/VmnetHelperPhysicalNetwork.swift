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

import ContainerNetworkServer
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import XPC

/// Describes an existing physical network that containers join through
/// vmnet bridged mode.
///
/// The subnet, gateway, and address assignments describe the external
/// LAN. The runtime creates the data path per container by launching a
/// vmnet-helper process on the configured host interface.
public final class VmnetHelperPhysicalNetwork: ContainerNetworkServer.Network, Sendable {
    /// The static configuration describing the external network.
    public struct Configuration: Sendable {
        public let id: String
        public let ipv4Subnet: CIDRv4
        public let ipv4Gateway: IPv4Address
        public let hostInterface: String
        public let pool: ClosedRange<UInt32>?
        public let helperPath: String?

        public init(
            id: String,
            ipv4Subnet: CIDRv4,
            ipv4Gateway: IPv4Address,
            hostInterface: String,
            pool: ClosedRange<UInt32>?,
            helperPath: String?
        ) throws {
            guard ipv4Subnet.contains(ipv4Gateway) else {
                throw ContainerizationError(.invalidArgument, message: "gateway \(ipv4Gateway) is not in subnet \(ipv4Subnet)")
            }
            // The network and broadcast addresses are not usable
            // gateways. In /31 and /32 networks every address is a
            // host address.
            if ipv4Subnet.prefix.length < 31 {
                guard ipv4Gateway != ipv4Subnet.lower, ipv4Gateway != ipv4Subnet.upper else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "gateway \(ipv4Gateway) is the network or broadcast address of \(ipv4Subnet)"
                    )
                }
            }
            if let pool {
                guard ipv4Subnet.contains(IPv4Address(pool.lowerBound)), ipv4Subnet.contains(IPv4Address(pool.upperBound)) else {
                    throw ContainerizationError(.invalidArgument, message: "address pool is not in subnet \(ipv4Subnet)")
                }
            }
            self.id = id
            self.ipv4Subnet = ipv4Subnet
            self.ipv4Gateway = ipv4Gateway
            self.hostInterface = hostInterface
            self.pool = pool
            self.helperPath = helperPath
        }
    }

    public let configuration: Configuration
    private let log: Logger

    public init(configuration: Configuration, log: Logger) {
        self.configuration = configuration
        self.log = log
    }

    public var id: String { configuration.id }

    // The vmnet-helper plugin has a single, default interface strategy, so
    // it reports no variant. The runtime selects its strategy by plugin
    // name alone (see NetworkInterfaceKey registration).
    public nonisolated var variant: String? { nil }

    public var status: NetworkStatus? {
        NetworkStatus(
            ipv4Subnet: configuration.ipv4Subnet,
            ipv4Gateway: configuration.ipv4Gateway,
            ipv6Subnet: nil
        )
    }

    public func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        let message = XPCMessage(object: xpc_dictionary_create(nil, nil, 0))
        message.set(key: VmnetHelperNetwork.AdditionalDataKey.interface.rawValue, value: configuration.hostInterface)
        if let helperPath = configuration.helperPath {
            message.set(key: VmnetHelperNetwork.AdditionalDataKey.helperPath.rawValue, value: helperPath)
        }
        try handler(message)
    }

    public func start() async throws {
        log.info(
            "started vmnet-helper network",
            metadata: [
                "id": "\(configuration.id)",
                "subnet": "\(configuration.ipv4Subnet)",
                "gateway": "\(configuration.ipv4Gateway)",
                "hostInterface": "\(configuration.hostInterface)",
            ])
    }
}
