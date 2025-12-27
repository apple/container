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

import DNS
import Foundation
import Logging
import NIOCore
import NIOPosix

/// Manages DNS server listeners on multiple addresses.
/// Supports dynamic addition of listeners when networks become available.
public actor DNSServerManager {
    private let handler: DNSHandler
    private let port: Int
    private let log: Logger?
    private var listeners: [String: Task<Void, Error>] = [:]
    private var channels: [String: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>] = [:]

    public init(handler: DNSHandler, port: Int, log: Logger? = nil) {
        self.handler = handler
        self.port = port
        self.log = log
    }

    /// Adds a DNS listener on the specified host address.
    /// - Parameter host: The IP address to bind to (e.g., "127.0.0.1" or "192.168.64.1")
    public func addListener(host: String) async throws {
        guard listeners[host] == nil else {
            log?.debug("DNS listener already exists for \(host)")
            return
        }

        log?.info("Adding DNS listener", metadata: ["host": "\(host)", "port": "\(port)"])

        let channel = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port)
            .flatMapThrowing { channel in
                try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: NIOAsyncChannel.Configuration(
                        inboundType: AddressedEnvelope<ByteBuffer>.self,
                        outboundType: AddressedEnvelope<ByteBuffer>.self
                    )
                )
            }
            .get()

        channels[host] = channel

        // Capture handler reference for use in task
        let handlerCopy = self.handler
        let logCopy = self.log

        let task = Task {
            try await channel.executeThenClose { inbound, outbound in
                for try await var packet in inbound {
                    try await Self.handlePacket(handler: handlerCopy, outbound: outbound, packet: &packet, log: logCopy)
                }
            }
        }

        listeners[host] = task
        log?.info("DNS listener started", metadata: ["host": "\(host)", "port": "\(port)"])
    }

    /// Removes a DNS listener for the specified host address.
    /// - Parameter host: The IP address to stop listening on
    public func removeListener(host: String) async {
        guard let task = listeners[host] else {
            log?.debug("No DNS listener found for \(host)")
            return
        }

        log?.info("Removing DNS listener", metadata: ["host": "\(host)"])
        task.cancel()
        listeners.removeValue(forKey: host)

        if let channel = channels.removeValue(forKey: host) {
            try? await channel.channel.close()
        }
    }

    /// Returns the list of hosts currently being listened on.
    public func activeHosts() -> [String] {
        Array(listeners.keys)
    }

    /// Waits for all listeners to complete (used for graceful shutdown).
    public func waitForAll() async {
        for (_, task) in listeners {
            _ = try? await task.value
        }
    }

    private static func handlePacket(
        handler: DNSHandler,
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>,
        packet: inout AddressedEnvelope<ByteBuffer>,
        log: Logger?
    ) async throws {
        let chunkSize = 512
        var data = Data()

        while packet.data.readableBytes > 0 {
            if let chunk = packet.data.readBytes(length: min(chunkSize, packet.data.readableBytes)) {
                data.append(contentsOf: chunk)
            }
        }

        let query = try Message(deserialize: data)
        log?.debug("processing query: \(query.questions)")

        let responseData: Data
        do {
            var response =
                try await handler.answer(query: query)
                ?? Message(
                    id: query.id,
                    type: .response,
                    returnCode: .notImplemented,
                    questions: query.questions,
                    answers: []
                )

            // Only set NXDOMAIN if handler didn't explicitly set noError (NODATA response).
            if response.answers.isEmpty && response.returnCode != .noError {
                response.returnCode = .nonExistentDomain
            }

            responseData = try response.serialize()
        } catch {
            log?.error("error processing DNS message: \(error)")
            let response = Message(
                id: query.id,
                type: .response,
                returnCode: .notImplemented,
                questions: query.questions,
                answers: []
            )
            responseData = try response.serialize()
        }

        let rData = ByteBuffer(bytes: responseData)
        try? await outbound.write(AddressedEnvelope(remoteAddress: packet.remoteAddress, data: rData))
    }
}
