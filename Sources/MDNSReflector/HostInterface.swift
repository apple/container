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

import ContainerizationExtras
import Darwin

/// A snapshot of a network interface of the host.
public struct HostInterface: Hashable, Sendable {
    /// An IP network that an interface is attached to.
    public struct Subnet: Hashable, Sendable {
        /// The network address, which is an address with its host bits cleared.
        public let network: IPAddress

        /// The number of leading bits that identify the network.
        public let prefixLength: UInt8

        public init(network: IPAddress, prefixLength: UInt8) {
            self.network = network
            self.prefixLength = prefixLength
        }

        /// Whether the subnet is the link-local one that every interface has,
        /// which says nothing about which link an interface is attached to.
        public var isLinkLocal: Bool {
            switch network {
            case .v4(let address): address.isLinkLocal
            case .v6(let address): address.isLinkLocal
            }
        }
    }

    /// The name of the interface, such as `en0`.
    public let name: String

    /// The index of the interface.
    public let index: UInt32

    /// The addresses assigned to the interface.
    public let addresses: [IPAddress]

    /// The networks of the addresses assigned to the interface.
    public let subnets: [Subnet]

    /// Whether the interface is up and running.
    public let isUp: Bool

    /// Whether the interface is a loopback interface.
    public let isLoopback: Bool

    /// Whether the interface is a point-to-point link, such as a VPN tunnel.
    public let isPointToPoint: Bool

    /// Whether the interface supports multicast.
    public let supportsMulticast: Bool

    public init(
        name: String,
        index: UInt32,
        addresses: [IPAddress],
        subnets: [Subnet] = [],
        isUp: Bool = true,
        isLoopback: Bool = false,
        isPointToPoint: Bool = false,
        supportsMulticast: Bool = true
    ) {
        self.name = name
        self.index = index
        self.addresses = addresses
        self.subnets = subnets
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
        self.supportsMulticast = supportsMulticast
    }

    /// Returns the current interfaces of the host, in the order that the
    /// system reports them.
    public static func current() -> [HostInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return []
        }
        defer { freeifaddrs(head) }

        var order: [String] = []
        var flagsByName: [String: UInt32] = [:]
        var addressesByName: [String: [IPAddress]] = [:]
        var subnetsByName: [String: [Subnet]] = [:]

        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = cursor.pointee
            let name = String(cString: entry.ifa_name)
            if flagsByName[name] == nil {
                order.append(name)
            }
            flagsByName[name] = entry.ifa_flags

            guard let socketAddress = entry.ifa_addr, let bytes = addressBytes(from: socketAddress), let address = ipAddress(bytes) else {
                continue
            }
            addressesByName[name, default: []].append(address)

            // The netmask has the layout of the address, but its family field is not reliable.
            let family = socketAddress.pointee.sa_family
            guard let mask = entry.ifa_netmask.flatMap({ addressBytes(from: $0, family: family) }), mask.count == bytes.count else {
                continue
            }
            let prefixLength = mask.reduce(0) { $0 + $1.nonzeroBitCount }
            if let network = ipAddress(zip(bytes, mask).map { $0 & $1 }) {
                subnetsByName[name, default: []].append(Subnet(network: network, prefixLength: UInt8(clamping: prefixLength)))
            }
        }

        return order.compactMap { name in
            let index = if_nametoindex(name)
            guard index != 0, let flags = flagsByName[name] else {
                return nil
            }
            return HostInterface(
                name: name,
                index: index,
                addresses: addressesByName[name] ?? [],
                subnets: subnetsByName[name] ?? [],
                isUp: flags & UInt32(IFF_UP) != 0 && flags & UInt32(IFF_RUNNING) != 0,
                isLoopback: flags & UInt32(IFF_LOOPBACK) != 0,
                isPointToPoint: flags & UInt32(IFF_POINTOPOINT) != 0,
                supportsMulticast: flags & UInt32(IFF_MULTICAST) != 0
            )
        }
    }

    /// The address bytes of a socket address, in network order.
    private static func addressBytes(from socketAddress: UnsafeMutablePointer<sockaddr>, family: sa_family_t? = nil) -> [UInt8]? {
        switch Int32(family ?? socketAddress.pointee.sa_family) {
        case AF_INET:
            return socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
        case AF_INET6:
            var bytes = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            // The kernel may embed the scope of a link-local address in the
            // second 16-bit word. It is not part of the address.
            if bytes.count == 16, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
                bytes[2] = 0
                bytes[3] = 0
            }
            return bytes
        default:
            return nil
        }
    }

    private static func ipAddress(_ bytes: [UInt8]) -> IPAddress? {
        switch bytes.count {
        case 4: (try? IPv4Address(bytes)).map { .v4($0) }
        case 16: (try? IPv6Address(bytes)).map { .v6($0) }
        default: nil
        }
    }
}
