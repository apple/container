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

import ContainerPersistence
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
        let subnet: CIDRAddress
        let gateway: IPv4Address
    }

    private let stateMutex: Mutex<State>
    private let log: Logger

    /// Configure a bridge network that allows external system access using
    /// network address translation.
    public init(
        configuration: NetworkConfiguration,
        log: Logger
    ) throws {
        guard configuration.mode == .nat else {
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

            let networkStatus = NetworkStatus(address: networkInfo.subnet.description, gateway: networkInfo.gateway.description)
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
        let subnetText = configuration.subnet ?? DefaultsStore.getOptional(key: .defaultSubnet)

        // with the reservation API, subnet priority is CLI argument, UserDefault, auto
        let subnet = try subnetText.map { try CIDRAddress($0) }

        // set up the vmnet configuration
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let vmnetConfiguration = vmnet_network_configuration_create(vmnet.operating_modes_t.VMNET_SHARED_MODE, &status), status == .VMNET_SUCCESS else {
            throw ContainerizationError(.unsupported, message: "failed to create vmnet config with status \(status)")
        }

        vmnet_network_configuration_disable_dhcp(vmnetConfiguration)

        // set the subnet if the caller provided one
        if let subnet {
            let gateway = IPv4Address(fromValue: subnet.lower.value + 1)
            var gatewayAddr = in_addr()
            inet_pton(AF_INET, gateway.description, &gatewayAddr)
            let mask = IPv4Address(fromValue: subnet.prefixLength.prefixMask32)
            var maskAddr = in_addr()
            inet_pton(AF_INET, mask.description, &maskAddr)
            log.info(
                "configuring vmnet subnet",
                metadata: ["cidr": "\(subnet)"]
            )
            let status = vmnet_network_configuration_set_ipv4_subnet(vmnetConfiguration, &gatewayAddr, &maskAddr)
            guard status == .VMNET_SUCCESS else {
                throw ContainerizationError(.internalError, message: "failed to set subnet \(subnet) for network \(configuration.id)")
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
        let lower = IPv4Address(fromValue: subnetValue & maskValue)
        let upper = IPv4Address(fromValue: lower.value + ~maskValue)
        let runningSubnet = try CIDRAddress(lower: lower, upper: upper)
        let runningGateway = IPv4Address(fromValue: runningSubnet.lower.value + 1)

        log.info(
            "started vmnet network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(configuration.mode)",
                "cidr": "\(runningSubnet)",
            ]
        )

        return NetworkInfo(network: network, subnet: runningSubnet, gateway: runningGateway)
    }
}
