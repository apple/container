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
import Logging

/// A network service that hands out static IPv4 addresses on a bridged
/// physical network.
///
/// Addresses are either requested explicitly per attachment (`ip=`) or
/// allocated from the optional `pool` configured on the network. The
/// service performs no DHCP, so the operator must keep assigned addresses
/// outside the LAN's DHCP range.
///
/// ContainerizationExtras' `AddressAllocator` is deliberately not used.
/// It manages one contiguous span, while this service combines a pool
/// with explicit addresses anywhere in the subnet plus hostname and
/// session ownership tracking.
public actor VmnetHelperNetworkService: NetworkService {
    private struct Allocation {
        let address: UInt32
        let owner: XPCServerSession
    }

    private let network: VmnetHelperPhysicalNetwork
    private let log: Logger
    private var allocationsByHostname: [String: Allocation] = [:]
    private var hostnamesBySession: [XPCServerSession: [String]] = [:]
    /// Address bookkeeping (in-use set, pool cursor, validation).
    private var addresses: AddressPool

    public init(network: VmnetHelperPhysicalNetwork, log: Logger) {
        self.network = network
        self.log = log
        self.addresses = AddressPool(configuration: network.configuration)
    }

    @Sendable
    public func status() async throws -> NetworkStatus {
        guard let status = network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) is not running")
        }
        return status
    }

    @Sendable
    public func allocate(
        hostname: String,
        macAddress: MACAddress?,
        ip: IPv4Address?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard macAddress == nil else {
            throw ContainerizationError(
                .unsupported,
                message: "network \(network.id) does not support explicit MAC addresses; vmnet assigns the MAC for bridged interfaces"
            )
        }

        let address: UInt32
        let isNewHostname = allocationsByHostname[hostname] == nil

        if let existing = allocationsByHostname[hostname] {
            // Repeated allocations for a hostname are valid only from
            // the owning session. Honoring another session would later
            // release an address that is still in use.
            guard existing.owner === session else {
                throw ContainerizationError(
                    .exists,
                    message: "hostname \(hostname) is already allocated by another client on network \(network.id)"
                )
            }
            if let requested = ip {
                guard requested.value == existing.address else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "hostname \(hostname) is already allocated address \(IPv4Address(existing.address)) on network \(network.id)"
                    )
                }
            }
            address = existing.address
        } else if let requested = ip {
            try addresses.validate(requested)
            guard !addresses.isAllocated(requested.value) else {
                throw ContainerizationError(.exists, message: "address \(requested) is already allocated on network \(network.id)")
            }
            address = requested.value
        } else {
            address = try addresses.allocateFromPool()
        }

        allocationsByHostname[hostname] = Allocation(address: address, owner: session)
        addresses.reserve(address)

        if hostnamesBySession[session] == nil {
            await session.onDisconnect { [weak self] in
                await self?.releaseSession(session)
            }
        }
        // A repeated allocation for an already-owned hostname returns the
        // same address; only track the hostname once so the session's
        // release list does not accumulate duplicates.
        if isNewHostname {
            hostnamesBySession[session, default: []].append(hostname)
        }

        let attachment = try makeAttachment(hostname: hostname, address: address)
        log.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "ipv4Address": "\(attachment.ipv4Address)",
                "ipv4Gateway": "\(attachment.ipv4Gateway)",
            ])

        var additionalData: XPCMessage?
        try network.withAdditionalData {
            additionalData = $0
        }

        return (attachment: attachment, additionalData: additionalData)
    }

    @Sendable
    public func lookup(hostname: String) async throws -> Attachment? {
        guard let allocation = allocationsByHostname[hostname] else {
            return nil
        }
        return try makeAttachment(hostname: hostname, address: allocation.address)
    }

    private func makeAttachment(hostname: String, address: UInt32) throws -> Attachment {
        let configuration = network.configuration
        return Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(IPv4Address(address), prefix: configuration.ipv4Subnet.prefix),
            ipv4Gateway: configuration.ipv4Gateway,
            ipv6Address: nil,
            // The MAC address is assigned by vmnet when the runtime starts
            // the per-container helper, so it is unknown at allocation time.
            macAddress: nil
        )
    }

    private func releaseSession(_ session: XPCServerSession) {
        guard let hostnames = hostnamesBySession.removeValue(forKey: session) else {
            return
        }
        for hostname in hostnames {
            // Release only allocations this session still owns.
            guard let allocation = allocationsByHostname[hostname], allocation.owner === session else {
                continue
            }
            allocationsByHostname.removeValue(forKey: hostname)
            addresses.release(allocation.address)
        }
        log.info("released session", metadata: ["hostnames": "\(hostnames.count)"])
    }
}
