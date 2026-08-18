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

import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

public actor DefaultNetworkService: NetworkService {
    private let network: any Network
    private let log: Logger
    private var allocator: AttachmentAllocator
    private var macAddresses: [UInt32: MACAddress]
    private var allocationsBySession: [XPCServerSession: [(hostname: String, index: UInt32)]]

    /// Set up a network service for the specified network.
    /// - Parameters:
    ///   - leases: keeps what each host was given, so a host attaching again is
    ///     given what it had. Nothing is remembered without one, which is what
    ///     a caller wanting a network that forgets passes.
    public init(
        network: any Network,
        leases: (any AttachmentLeaseStore)? = nil,
        log: Logger
    ) async throws {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        let subnet = status.ipv4Subnet
        let size = Int(subnet.upper.value - subnet.lower.value - 3)
        self.network = network
        self.log = log
        self.allocator = try await AttachmentAllocator(lower: subnet.lower.value + 2, size: size, store: leases, log: log)
        self.macAddresses = [:]
        self.allocationsBySession = [:]
    }

    @Sendable
    public func status() async throws -> NetworkStatus {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) is not running")
        }
        return status
    }

    @Sendable
    public func allocate(
        hostname: String,
        macAddress: MACAddress?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        // A hardware address is minted for a host that names none, and the one
        // a host was given before is handed back when it attaches again: the
        // address is what the network knows a host by, and an IPv6 address is
        // derived from it, so a host that comes back with a new one comes back
        // as somebody else.
        let requested = macAddress ?? MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
        let lease = try await allocator.allocate(hostname: hostname, macAddress: requested)
        let macAddress = macAddress ?? lease.macAddress
        let index = lease.index
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let ip = IPv4Address(index)
        let attachment = Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(ip, prefix: status.ipv4Subnet.prefix),
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress,
            variant: network.variant
        )
        log.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "ipv4Address": "\(attachment.ipv4Address)",
                "ipv4Gateway": "\(attachment.ipv4Gateway)",
                "ipv6Address": "\(attachment.ipv6Address?.description ?? "unavailable")",
                "macAddress": "\(attachment.macAddress?.description ?? "unspecified")",
            ])

        var additionalData: XPCMessage?
        try network.withAdditionalData {
            additionalData = $0
        }
        macAddresses[index] = macAddress

        let isNewSession = allocationsBySession[session] == nil
        allocationsBySession[session, default: []].append((hostname: hostname, index: index))
        if isNewSession {
            await session.onDisconnect { [weak self] in
                await self?.releaseSession(session)
            }
        }

        return (attachment: attachment, additionalData: additionalData)
    }

    private func releaseSession(_ session: XPCServerSession) async {
        guard let allocations = allocationsBySession.removeValue(forKey: session) else {
            return
        }
        for allocation in allocations {
            _ = try? await allocator.deallocate(hostname: allocation.hostname)
            macAddresses.removeValue(forKey: allocation.index)
        }
        log.info("released session", metadata: ["allocations": "\(allocations.count)"])
    }

    @Sendable
    public func lookup(hostname: String) async throws -> Attachment? {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        // Invariant: hostname -> index if and only if index -> MAC address
        let index = try await allocator.lookup(hostname: hostname)
        guard let index else {
            return nil
        }
        guard let macAddress = macAddresses[index] else {
            return nil
        }

        let address = IPv4Address(index)
        let subnet = status.ipv4Subnet
        let ipv4Address = try CIDRv4(address, prefix: subnet.prefix)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let attachment = Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: ipv4Address,
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress,
            variant: network.variant
        )
        log.debug(
            "lookup attachment",
            metadata: [
                "hostname": "\(hostname)",
                "address": "\(address)",
            ])

        return attachment
    }
}
