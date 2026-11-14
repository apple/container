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
import Darwin
import Foundation
import Logging
import Synchronization
import SystemConfiguration
import XPC
import vmnet

struct VmnetInterfaceAddress: Equatable {
    let name: String
    let flags: UInt32
    let family: Int32
    let ip: String
}

enum VmnetExternalInterfaceSelector {
    static func activePointToPointIPv4Interface(primaryInterface: String?, in addresses: [VmnetInterfaceAddress]) -> String? {
        guard let primaryInterface else {
            return nil
        }
        guard let address = addresses.first(where: { $0.name == primaryInterface }) else {
            return nil
        }
        guard address.family == AF_INET,
            address.flags & UInt32(IFF_UP) != 0,
            address.flags & UInt32(IFF_RUNNING) != 0,
            address.flags & UInt32(IFF_POINTOPOINT) != 0,
            address.ip != "127.0.0.1",
            isTunnelInterfaceName(address.name)
        else {
            return nil
        }
        return address.name
    }

    private static func isTunnelInterfaceName(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("tap") || name.hasPrefix("ppp")
    }
}

/// Creates a vmnet network with reservation APIs.
@available(macOS 26, *)
public final class ReservedVmnetNetwork: ContainerNetworkServer.Network {
    private struct State {
        var status: NetworkStatus?
        var network: vmnet_network_ref?
        var networkStateSignature: String?
    }

    private struct NetworkInfo {
        let network: vmnet_network_ref
        let ipv4Subnet: CIDRv4
        let ipv4Gateway: IPv4Address
        let ipv6Subnet: CIDRv6
        let externalInterface: String?
    }

    private let configuration: NetworkConfiguration
    private let stateMutex: Mutex<State>
    private let log: Logger
    private let networkStateSignatureProvider: @Sendable () -> String?

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
        self.configuration = configuration
        self.log = log
        self.networkStateSignatureProvider = ReservedVmnetNetwork.networkStateSignature
        stateMutex = Mutex(State())
        log.info("created vmnet network")
    }

    public nonisolated var id: String { configuration.id }

    public nonisolated var variant: String? { "reserved" }

    public var status: NetworkStatus? {
        stateMutex.withLock { $0.status }
    }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        try stateMutex.withLock { state in
            try refreshNetworkIfNeeded(state: &state)
            try handler(state.network.map { try Self.serialize_network_ref(ref: $0) })
        }
    }

    public func start() async throws {
        try stateMutex.withLock { state in
            guard state.status == nil else {
                throw ContainerizationError(.invalidArgument, message: "cannot start network \(configuration.id): already started")
            }

            let networkInfo = try startNetwork(configuration: configuration, log: log)

            state.status = Self.status(for: networkInfo)
            state.network = networkInfo.network
            state.networkStateSignature = networkStateSignatureProvider()
        }
    }

    private func refreshNetworkIfNeeded(state: inout State) throws {
        guard configuration.mode == .nat else {
            return
        }

        guard let currentSignature = networkStateSignatureProvider() else {
            return
        }

        guard state.networkStateSignature != nil, state.networkStateSignature != currentSignature else {
            return
        }

        log.info("network state changed, recreating vmnet network", metadata: ["id": "\(configuration.id)"])
        let previousStatus = state.status
        state.network = nil
        let networkInfo: NetworkInfo
        do {
            networkInfo = try startNetwork(
                configuration: configuration,
                log: log,
                preferredIPv4Subnet: previousStatus?.ipv4Subnet,
                preferredIPv6Subnet: previousStatus?.ipv6Subnet
            )
        } catch {
            guard configuration.ipv4Subnet == nil, configuration.ipv6Subnet == nil, previousStatus != nil else {
                throw error
            }
            log.info(
                "failed to recreate vmnet network with previous subnets, retrying automatic subnet selection",
                metadata: [
                    "id": "\(configuration.id)",
                    "error": "\(error)",
                ]
            )
            networkInfo = try startNetwork(configuration: configuration, log: log)
        }
        state.status = Self.status(for: networkInfo)
        state.network = networkInfo.network
        state.networkStateSignature = currentSignature
    }

    private static func status(for networkInfo: NetworkInfo) -> NetworkStatus {
        NetworkStatus(
            ipv4Subnet: networkInfo.ipv4Subnet,
            ipv4Gateway: networkInfo.ipv4Gateway,
            ipv6Subnet: networkInfo.ipv6Subnet
        )
    }

    private static func networkStateSignature() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "com.apple.container.network-vmnet" as CFString, nil, nil) else {
            return nil
        }

        let patterns =
            [
                "State:/Network/Global/IPv4",
                "State:/Network/Global/IPv6",
                "State:/Network/Interface/.*/IPv4",
                "State:/Network/Interface/.*/IPv6",
            ] as CFArray

        guard let values = SCDynamicStoreCopyMultiple(store, nil, patterns) as? [String: Any] else {
            return nil
        }

        var parts = [String]()
        for key in values.keys.sorted() {
            guard let value = values[key],
                let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            else {
                continue
            }
            parts.append("\(key)=\(data.base64EncodedString())")
        }

        parts += interfaceAddressSignature()

        return parts.joined(separator: "|")
    }

    private static func interfaceAddressSignature() -> [String] {
        interfaceAddresses().map { address in
            switch address.family {
            case AF_INET:
                return "ifaddr4:\(address.name)=\(address.ip)"
            case AF_INET6:
                return "ifaddr6:\(address.name)=\(address.ip)"
            default:
                return nil
            }
        }
        .compactMap { $0 }
        .sorted()
    }

    private static func interfaceAddresses() -> [VmnetInterfaceAddress] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            return []
        }
        defer { freeifaddrs(firstAddress) }

        var parts = [VmnetInterfaceAddress]()
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = current {
            defer { current = address.pointee.ifa_next }
            guard let socketAddress = address.pointee.ifa_addr else {
                continue
            }

            let name = stringFromNullTerminatedCString(address.pointee.ifa_name)
            let family = Int32(socketAddress.pointee.sa_family)
            switch family {
            case AF_INET:
                guard let ip = ipv4AddressString(socketAddress) else {
                    continue
                }
                parts.append(VmnetInterfaceAddress(name: name, flags: address.pointee.ifa_flags, family: family, ip: ip))
            case AF_INET6:
                guard let ip = ipv6AddressString(socketAddress) else {
                    continue
                }
                parts.append(VmnetInterfaceAddress(name: name, flags: address.pointee.ifa_flags, family: family, ip: ip))
            default:
                continue
            }
        }

        return parts
    }

    private static func activePointToPointIPv4Interface() -> String? {
        VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(
            primaryInterface: primaryIPv4Interface(),
            in: interfaceAddresses()
        )
    }

    private static func primaryIPv4Interface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "com.apple.container.network-vmnet" as CFString, nil, nil) else {
            return nil
        }
        guard let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return globalIPv4["PrimaryInterface"] as? String
    }

    private static func ipv4AddressString(_ socketAddress: UnsafeMutablePointer<sockaddr>) -> String? {
        var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            pointer.pointee.sin_addr
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return stringFromNullTerminatedBuffer(buffer)
    }

    private static func ipv6AddressString(_ socketAddress: UnsafeMutablePointer<sockaddr>) -> String? {
        var address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            pointer.pointee.sin6_addr
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return stringFromNullTerminatedBuffer(buffer)
    }

    private static func stringFromNullTerminatedBuffer(_ buffer: [CChar]) -> String? {
        guard let endIndex = buffer.firstIndex(of: 0) else {
            return nil
        }
        let bytes = buffer[..<endIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func stringFromNullTerminatedCString(_ pointer: UnsafePointer<CChar>) -> String {
        var bytes = [UInt8]()
        var offset = 0
        while pointer[offset] != 0 {
            bytes.append(UInt8(bitPattern: pointer[offset]))
            offset += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func serialize_network_ref(ref: vmnet_network_ref) throws -> XPCMessage {
        var status: vmnet_return_t = .VMNET_SUCCESS
        guard let refObject = vmnet_network_copy_serialization(ref, &status) else {
            throw ContainerizationError(.invalidArgument, message: "cannot serialize vmnet_network_ref to XPC object, status \(status)")
        }
        return XPCMessage(object: refObject)
    }

    private func startNetwork(
        configuration: NetworkConfiguration,
        log: Logger,
        preferredIPv4Subnet: CIDRv4? = nil,
        preferredIPv6Subnet: CIDRv6? = nil
    ) throws -> NetworkInfo {
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

        let externalInterface = configuration.mode == .nat ? Self.activePointToPointIPv4Interface() : nil
        if let externalInterface {
            let status = externalInterface.withCString {
                vmnet_network_configuration_set_external_interface(vmnetConfiguration, $0)
            }
            guard status == .VMNET_SUCCESS else {
                throw ContainerizationError(.internalError, message: "failed to set external interface \(externalInterface) for network \(configuration.id)")
            }
            log.info(
                "configuring vmnet external interface",
                metadata: ["interface": "\(externalInterface)"]
            )
        }

        let ipv4Subnet = configuration.ipv4Subnet ?? preferredIPv4Subnet
        let ipv6Subnet = configuration.ipv6Subnet ?? preferredIPv6Subnet

        // set the IPv4 subnet
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

        // set the IPv6 network prefix
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
                "externalInterface": "\(externalInterface ?? "")",
            ]
        )

        return NetworkInfo(
            network: network,
            ipv4Subnet: runningSubnet,
            ipv4Gateway: runningGateway,
            ipv6Subnet: runningV6Subnet,
            externalInterface: externalInterface
        )
    }
}
