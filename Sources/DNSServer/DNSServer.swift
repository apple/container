//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import Foundation
import Logging
import NIOCore
import NIOPosix

/// Provides a DNS server.
/// - Parameters:
///   - host: The host address on which to listen.
///   - port: The port for the server to listen.
public struct DNSServer {
    public var handler: DNSHandler
    let log: Logger?

    public init(
        handler: DNSHandler,
        log: Logger? = nil
    ) {
        self.handler = handler
        self.log = log
    }

    /// A bound UDP listener that can be passed to `run(listener:)` once the DNS handler is ready.
    public struct Listener: Sendable {
        fileprivate let channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>

        var localPort: Int? { channel.channel.localAddress?.port }

        public func close() async {
            channel.channel.close(promise: nil)
            try? await channel.channel.closeFuture.get()
        }
    }

    public static func bind(host: String, port: Int) async throws -> Listener {
        // TODO: TCP server
        let channel = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: NIOAsyncChannel.Configuration(
                            inboundType: AddressedEnvelope<ByteBuffer>.self,
                            outboundType: AddressedEnvelope<ByteBuffer>.self
                        )
                    )
                }
            }
        return Listener(channel: channel)
    }

    public func run(host: String, port: Int) async throws {
        let listener = try await Self.bind(host: host, port: port)
        try await run(listener: listener)
    }

    public func run(listener: Listener) async throws {
        try await listener.channel.executeThenClose { inbound, outbound in
            for try await var packet in inbound {
                try await self.handle(outbound: outbound, packet: &packet)
            }
        }
    }

    public func run(socketPath: String) async throws {
        // TODO: TCP server
        let srv = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true)
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

        try await srv.executeThenClose { inbound, outbound in
            for try await var packet in inbound {
                log?.debug("received packet from \(packet.remoteAddress)")
                try await self.handle(outbound: outbound, packet: &packet)
                log?.debug("sent packet")
            }
        }
    }

    public func stop() async throws {}
}
