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

import ContainerPersistence
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import Dispatch
import Foundation
import Logging
import Synchronization
import SystemConfiguration
import XPC
import vmnet

/// Creates a vmnet network with reservation APIs.
@available(macOS 26, *)
public final class ReservedVmnetNetwork: Network {
    private struct State {
        var networkState: NetworkState
        var network: vmnet_network_ref?
    }

    private struct NetworkInfo {
        let network: vmnet_network_ref
        let ipv4Subnet: CIDRv4
        let ipv4Gateway: IPv4Address
        let ipv6Subnet: CIDRv6
    }

    private let stateMutex: Mutex<State>
    private let log: Logger

    /// Configure a bridge network that allows external system access using
    /// network address translation.
    public init(
        configuration: NetworkConfiguration,
        log: Logger
    ) throws {
        guard configuration.mode == .nat || configuration.mode == .hostOnly else {
            throw ContainerizationError(.unsupported, message: "invalid network mode \(configuration.mode)")
        }

        log.info("creating vmnet network")
        self.log = log
        let initialState = State(networkState: .created(configuration))
        stateMutex = Mutex(initialState)
        log.info("created vmnet network")
    }

    public var state: NetworkState {
        stateMutex.withLock { $0.networkState }
    }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        try stateMutex.withLock { state in
            try handler(state.network.map { try Self.serialize_network_ref(ref: $0) })
        }
    }

    public func start() async throws {
        try stateMutex.withLock { state in
            guard case .created(let configuration) = state.networkState else {
                throw ContainerizationError(.invalidArgument, message: "cannot start network that is in \(state.networkState.state) state")
            }

            let networkInfo = try startNetwork(configuration: configuration, log: log)

            let networkStatus = NetworkStatus(
                ipv4Subnet: networkInfo.ipv4Subnet,
                ipv4Gateway: networkInfo.ipv4Gateway,
                ipv6Subnet: networkInfo.ipv6Subnet,
            )
            state.networkState = NetworkState.running(configuration, networkStatus)
            state.network = networkInfo.network
        }
    }

    private static func serialize_network_ref(ref: vmnet_network_ref) throws -> XPCMessage {
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let refObject = vmnet_network_copy_serialization(ref, &status) else {
            throw ContainerizationError(.invalidArgument, message: "cannot serialize vmnet_network_ref to XPC object, status \(status)")
        }
        return XPCMessage(object: refObject)
    }

    private func startNetwork(configuration: NetworkConfiguration, log: Logger) throws -> NetworkInfo {
        log.info(
            "starting vmnet network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(configuration.mode)",
            ]
        )

        // set up the vmnet configuration
        var status: vmnet_return_t = .VMNET_SUCCESS
        let mode: vmnet.operating_modes_t = configuration.mode == .hostOnly ? .VMNET_HOST_MODE : .VMNET_SHARED_MODE
        guard let vmnetConfiguration = vmnet_network_configuration_create(mode, &status), status == .VMNET_SUCCESS else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet config with status \(status)")
        }

        vmnet_network_configuration_disable_dhcp(vmnetConfiguration)

        // subnet priority is CLI argument, UserDefault, auto
        let defaultIpv4Subnet = try DefaultsStore.getOptional(key: .defaultSubnet).map { try CIDRv4($0) }
        let ipv4Subnet = configuration.ipv4Subnet ?? defaultIpv4Subnet
        let defaultIpv6Subnet = try DefaultsStore.getOptional(key: .defaultIPv6Subnet).map { try CIDRv6($0) }
        let ipv6Subnet = configuration.ipv6Subnet ?? defaultIpv6Subnet

        // set the IPv4 subnet if the caller provided one
        if let ipv4Subnet {
            let gateway = IPv4Address(ipv4Subnet.lower.value + 1)
            var gatewayAddr = in_addr()
            inet_pton(AF_INET, gateway.description, &gatewayAddr)
            let mask = IPv4Address(ipv4Subnet.prefix.prefixMask32)
            var maskAddr = in_addr()
            inet_pton(AF_INET, mask.description, &maskAddr)
            log.info(
                "configuring vmnet IPv4 subnet",
                metadata: ["cidr": "\(ipv4Subnet)"]
            )
            let status = vmnet_network_configuration_set_ipv4_subnet(vmnetConfiguration, &gatewayAddr, &maskAddr)
            guard status == .VMNET_SUCCESS else {
                throw ContainerizationError(.internalError, message: "failed to set subnet \(ipv4Subnet) for IPv4 network \(configuration.id)")
            }
        }

        // set the IPv6 network prefix if the caller provided one
        if let ipv6Subnet {
            let gateway = IPv6Address(ipv6Subnet.lower.value + 1)
            var gatewayAddr = in6_addr()
            inet_pton(AF_INET6, gateway.description, &gatewayAddr)
            log.info(
                "configuring vmnet IPv6 prefix",
                metadata: ["cidr": "\(ipv6Subnet)"]
            )
            let status = vmnet_network_configuration_set_ipv6_prefix(vmnetConfiguration, &gatewayAddr, ipv6Subnet.prefix.length)
            guard status == .VMNET_SUCCESS else {
                throw ContainerizationError(.internalError, message: "failed to set prefix \(ipv6Subnet) for IPv6 network \(configuration.id)")
            }
        }

        // reserve the network
        guard let network = vmnet_network_create(vmnetConfiguration, &status), status == .VMNET_SUCCESS else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet network with status \(status)")
        }

        // retrieve the subnet since the caller may not have provided one
        var subnetAddr = in_addr()
        var maskAddr = in_addr()
        vmnet_network_get_ipv4_subnet(network, &subnetAddr, &maskAddr)
        let subnetValue = UInt32(bigEndian: subnetAddr.s_addr)
        let maskValue = UInt32(bigEndian: maskAddr.s_addr)
        let lower = IPv4Address(subnetValue & maskValue)
        let upper = IPv4Address(lower.value + ~maskValue)
        let runningSubnet = try CIDRv4(lower: lower, upper: upper)
        let runningGateway = IPv4Address(runningSubnet.lower.value + 1)

        var prefixAddr = in6_addr()
        var prefixLength = UInt8(0)
        vmnet_network_get_ipv6_prefix(network, &prefixAddr, &prefixLength)
        guard let prefix = Prefix(length: prefixLength) else {
            throw ContainerizationError(.internalError, message: "invalid IPv6 prefix length \(prefixLength) for network \(configuration.id)")
        }
        let prefixIpv6Bytes = withUnsafeBytes(of: prefixAddr.__u6_addr.__u6_addr8) {
            Array($0)
        }
        let prefixIpv6Addr = try IPv6Address(prefixIpv6Bytes)
        let runningV6Subnet = try CIDRv6(prefixIpv6Addr, prefix: prefix)

        log.info(
            "started vmnet network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(configuration.mode)",
                "cidr": "\(runningSubnet)",
                "cidrv6": "\(runningV6Subnet)",
            ]
        )

        return NetworkInfo(
            network: network,
            ipv4Subnet: runningSubnet,
            ipv4Gateway: runningGateway,
            ipv6Subnet: runningV6Subnet,
        )
    }
}
