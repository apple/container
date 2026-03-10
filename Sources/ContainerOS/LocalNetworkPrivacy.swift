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

#if os(macOS)
import Darwin

/// Utility for triggering local network privacy alert.
/// The local networking privacy feature introduced in
/// macOS 15 requires users to authorize an app before it can
/// access peers on the local network. This security feature
/// affects runtime helpers that publish ports on the loopback
/// interface.
///
/// The approach used here is for the application to trigger
/// the alert before clients attemot to communicate with it.
/// This is a best effort method; there is no guarantee that
/// the alert will display.
///
/// See https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
/// for additional details.
package struct LocalNetworkPrivacy {
    /// Attempts to trigger the local network privacy alert.
    ///
    /// This builds a list of link-local IPv6 addresses and then creates a connected
    /// UDP socket to each in turn.  Connecting a UDP socket triggers the local
    /// network alert without actually sending any traffic.
    package static func triggerLocalNetworkPrivacyAlert() {
        let addresses = selectedLinkLocalIPv6Addresses()
        for address in addresses {
            let sock6 = socket(AF_INET6, SOCK_DGRAM, 0)
            guard sock6 >= 0 else { return }
            defer { close(sock6) }

            withUnsafePointer(to: address) { sa6 in
                sa6.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = connect(sock6, sa, socklen_t(sa.pointee.sa_len)) >= 0
                }
            }
        }
    }

    private static func selectedLinkLocalIPv6Addresses() -> [sockaddr_in6] {
        // Find the link-local broadcast-capable IPv6 interfaces, and
        // for each, create two peer socket addresses for the interface
        // with the port set to the discard service (port 9).
        let r1 = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let r2 = (0..<8).map { _ in UInt8.random(in: 0...255) }
        return Array(
            ipv6AddressesOfBroadcastCapableInterfaces()
                .filter { isIPv6AddressLinkLocal($0) }
                .map {
                    var addr = $0
                    addr.sin6_port = UInt16(9).bigEndian
                    return addr
                }
                .map { [setIPv6LinkLocalAddressHostPart(of: $0, to: r1), setIPv6LinkLocalAddressHostPart(of: $0, to: r2)] }
                .joined())
    }

    private static func setIPv6LinkLocalAddressHostPart(of address: sockaddr_in6, to hostPart: [UInt8]) -> sockaddr_in6 {
        // Set the host part (the bottom 64 bits) of the supplied
        // IPv6 socket address.
        precondition(hostPart.count == 8)
        var result = address
        withUnsafeMutableBytes(of: &result.sin6_addr) { buf in
            buf[8...].copyBytes(from: hostPart)
        }
        return result
    }

    private static func isIPv6AddressLinkLocal(_ address: sockaddr_in6) -> Bool {
        // Link-local address have the fe:c0/10 prefix.
        address.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe
            && (address.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0) == 0x80
    }

    private static func ipv6AddressesOfBroadcastCapableInterfaces() -> [sockaddr_in6] {
        // Iterate all interfaces and return the IPv6 addresses
        // for those that can broadcast.
        var addrList: UnsafeMutablePointer<ifaddrs>? = nil
        let err = getifaddrs(&addrList)
        guard err == 0, let start = addrList else { return [] }
        defer { freeifaddrs(start) }
        return sequence(first: start, next: { $0.pointee.ifa_next })
            .compactMap { i -> sockaddr_in6? in
                guard
                    (i.pointee.ifa_flags & UInt32(bitPattern: IFF_BROADCAST)) != 0,
                    let sa = i.pointee.ifa_addr,
                    sa.pointee.sa_family == AF_INET6,
                    sa.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size
                else { return nil }
                return UnsafeRawPointer(sa).load(as: sockaddr_in6.self)
            }
    }
}
#endif
