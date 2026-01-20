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

    public func run(host: String, port: Int) async throws {
        // TODO: TCP server
        let srv = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
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

        try await srv.executeThenClose { inbound, outbound in
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
