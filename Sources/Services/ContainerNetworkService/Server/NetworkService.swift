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

import ContainerNetworkServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

public actor NetworkService: Sendable {
    private let network: any Network
    private let log: Logger?
    private var allocator: AttachmentAllocator
    private var macAddresses: [UInt32: MACAddress]

    /// Set up a network service for the specified network.
    public init(
        network: any Network,
        log: Logger? = nil
    ) async throws {
        let state = await network.state
        guard case .running(_, let status) = state else {
            throw ContainerizationError(.invalidState, message: "invalid network state - network \(state.id) must be running")
        }

        let subnet = status.ipv4Subnet

        let size = Int(subnet.upper.value - subnet.lower.value - 3)
        self.allocator = try AttachmentAllocator(lower: subnet.lower.value + 2, size: size)
        self.macAddresses = [:]
        self.network = network
        self.log = log
    }

    @Sendable
    public func state(_ message: XPCMessage) async throws -> XPCMessage {
        let reply = message.reply()
        let state = await network.state
        try reply.setState(state)
        return reply
    }

    @Sendable
    public func allocate(_ message: XPCMessage) async throws -> XPCMessage {
        let state = await network.state
        guard case .running(_, let status) = state else {
            throw ContainerizationError(.invalidState, message: "invalid network state - network \(state.id) must be running")
        }

        let hostname = try message.hostname()
        let macAddress =
            try message.string(key: NetworkKeys.macAddress.rawValue)
            .map { try MACAddress($0) }
            ?? MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
        let index = try await allocator.allocate(hostname: hostname)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let ip = IPv4Address(index)
        let attachment = Attachment(
            network: state.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(ip, prefix: status.ipv4Subnet.prefix),
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress
        )
        log?.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "ipv4Address": "\(attachment.ipv4Address)",
                "ipv4Gateway": "\(attachment.ipv4Gateway)",
                "ipv6Address": "\(attachment.ipv6Address?.description ?? "unavailable")",
                "macAddress": "\(attachment.macAddress?.description ?? "unspecified")",
            ])
        let reply = message.reply()
        try reply.setAttachment(attachment)
        try network.withAdditionalData {
            if let additionalData = $0 {
                try reply.setAdditionalData(additionalData.underlying)
            }
        }
        macAddresses[index] = macAddress
        return reply
    }

    @Sendable
    public func deallocate(_ message: XPCMessage) async throws -> XPCMessage {
        let hostname = try message.hostname()
        if let index = try await allocator.deallocate(hostname: hostname) {
            macAddresses.removeValue(forKey: index)
        }
        log?.info("released attachments", metadata: ["hostname": "\(hostname)"])
        return message.reply()
    }

    @Sendable
    public func lookup(_ message: XPCMessage) async throws -> XPCMessage {
        let state = await network.state
        guard case .running(_, let status) = state else {
            throw ContainerizationError(.invalidState, message: "invalid network state - network \(state.id) must be running")
        }

        let hostname = try message.hostname()
        let index = try await allocator.lookup(hostname: hostname)
        let reply = message.reply()
        guard let index else {
            return reply
        }
        guard let macAddress = macAddresses[index] else {
            return reply
        }
        let address = IPv4Address(index)
        let subnet = status.ipv4Subnet
        let ipv4Address = try CIDRv4(address, prefix: subnet.prefix)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let attachment = Attachment(
            network: state.id,
            hostname: hostname,
            ipv4Address: ipv4Address,
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress
        )
        log?.debug(
            "lookup attachment",
            metadata: [
                "hostname": "\(hostname)",
                "address": "\(address)",
            ])
        try reply.setAttachment(attachment)
        return reply
    }

    @Sendable
    public func disableAllocator(_ message: XPCMessage) async throws -> XPCMessage {
        let success = await allocator.disableAllocator()
        log?.info("attempted allocator disable", metadata: ["success": "\(success)"])
        let reply = message.reply()
        reply.setAllocatorDisabled(success)
        return reply
    }
}

extension XPCMessage {
    fileprivate func setAdditionalData(_ additionalData: xpc_object_t) throws {
        xpc_dictionary_set_value(self.underlying, NetworkKeys.additionalData.rawValue, additionalData)
    }

    fileprivate func setAllocatorDisabled(_ allocatorDisabled: Bool) {
        self.set(key: NetworkKeys.allocatorDisabled.rawValue, value: allocatorDisabled)
    }

    fileprivate func setAttachment(_ attachment: Attachment) throws {
        let data = try JSONEncoder().encode(attachment)
        self.set(key: NetworkKeys.attachment.rawValue, value: data)
    }

    fileprivate func setState(_ state: NetworkState) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: NetworkKeys.state.rawValue, value: data)
    }
}
