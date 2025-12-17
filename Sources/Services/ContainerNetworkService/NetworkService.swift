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

import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

public actor NetworkService: Sendable {
    private let network: any Network
    private let log: Logger?
    private var allocator: AttachmentAllocator

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
        let macAddress = message.string(key: NetworkKeys.macAddress.rawValue)
        let index = try await allocator.allocate(hostname: hostname)
        let subnet = status.ipv4Subnet
        let ip = IPv4Address(index)
        let attachment = Attachment(
            network: state.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(ip, prefix: subnet.prefix),
            ipv4Gateway: status.ipv4Gateway,
            macAddress: macAddress
        )
        log?.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "ipv4Address": "\(attachment.ipv4Address)",
                "ipv4Gateway": "\(attachment.ipv4Gateway)",
                "macAddress": "\(macAddress ?? "auto")",
            ])
        let reply = message.reply()
        try reply.setAttachment(attachment)
        try network.withAdditionalData {
            if let additionalData = $0 {
                try reply.setAdditionalData(additionalData.underlying)
            }
        }
        return reply
    }

    @Sendable
    public func deallocate(_ message: XPCMessage) async throws -> XPCMessage {
        let hostname = try message.hostname()
        try await allocator.deallocate(hostname: hostname)
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

        let address = IPv4Address(index)
        let subnet = status.ipv4Subnet
        let attachment = Attachment(
            network: state.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(address, prefix: subnet.prefix),
            ipv4Gateway: status.ipv4Gateway
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
