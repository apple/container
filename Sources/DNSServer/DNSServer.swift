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
import Synchronization

/// Thread-safe active-connection counter used to enforce `maxConcurrentConnections`.
///
/// Wrapped in a `final class` so it can be stored as a reference in the
/// `Copyable` `DNSServer` struct without running into `~Copyable` restrictions.
private final class ConnectionCounter: Sendable {
    private let storage: Mutex<Int> = .init(0)

    func tryIncrement(limit: Int) -> Bool {
        storage.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func decrement() {
        storage.withLock { $0 -= 1 }
    }
}

/// Provides a DNS server over UDP and TCP.
public struct DNSServer: @unchecked Sendable {
    public var handler: DNSHandler
    let log: Logger?

    /// Maximum number of concurrent TCP connections.
    /// Connections beyond this limit are closed immediately. The UDP path is unaffected.
    static let maxConcurrentConnections = 128

    /// Generous upper bound on a DNS message received over TCP.
    /// Legitimate messages are well under this limit; anything larger almost certainly
    /// indicates a framing desync rather than a valid query, so we close the connection
    /// instead of trying to allocate a huge buffer.
    static let maxTCPMessageSize: UInt16 = 4096

    /// How long a TCP connection may be idle between fully-processed messages before
    /// it is closed. Exposed as an instance property so tests can inject a short value.
    let tcpIdleTimeout: Duration

    /// Active TCP connection counter.
    private let connections: ConnectionCounter

    public init(
        handler: DNSHandler,
        log: Logger? = nil,
        tcpIdleTimeout: Duration = .seconds(30)
    ) {
        self.handler = handler
        self.log = log
        self.tcpIdleTimeout = tcpIdleTimeout
        self.connections = ConnectionCounter()
    }

    // MARK: - UDP

    /// Runs a UDP DNS listener on the given host and port.
    public func run(host: String, port: Int) async throws {
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

    /// Runs a UDP DNS listener on a Unix domain socket.
    public func run(socketPath: String) async throws {
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

    // MARK: - TCP

    /// Runs a TCP DNS listener on the given host and port.
    ///
    /// DNS over TCP is required by RFC 1035 for responses that exceed 512 bytes (the UDP
    /// wire limit). Clients signal truncation via the TC bit and retry over TCP.
    /// This method runs a separate TCP server on the same port number as the UDP listener;
    /// the OS distinguishes them by socket type (SOCK_STREAM vs SOCK_DGRAM).
    public func runTCP(host: String, port: Int) async throws {
        let server = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(
                host: host,
                port: port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: ByteBuffer.self,
                            outboundType: ByteBuffer.self
                        )
                    )
                }
            }

        try await server.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { group in
                for try await child in inbound {
                    guard connections.tryIncrement(limit: Self.maxConcurrentConnections) else {
                        log?.warning(
                            "TCP DNS: connection limit (\(Self.maxConcurrentConnections)) reached, dropping connection")
                        continue
                    }

                    group.addTask {
                        defer { self.connections.decrement() }
                        await self.handleTCP(channel: child)
                    }
                }
            }
        }
    }

    /// Runs a TCP DNS listener on a Unix domain socket.
    ///
    /// Mirrors `runTCP(host:port:)` but binds to a socket file path instead of a
    /// TCP/IP address. Any existing socket file at the path is removed before binding.
    public func runTCP(socketPath: String) async throws {
        try? FileManager.default.removeItem(atPath: socketPath)

        let address = try SocketAddress(unixDomainSocketPath: socketPath)
        let server = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .bind(to: address) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: ByteBuffer.self,
                            outboundType: ByteBuffer.self
                        )
                    )
                }
            }

        try await server.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { group in
                for try await child in inbound {
                    guard connections.tryIncrement(limit: Self.maxConcurrentConnections) else {
                        log?.warning(
                            "TCP DNS: connection limit (\(Self.maxConcurrentConnections)) reached, dropping connection")
                        continue
                    }

                    group.addTask {
                        defer { self.connections.decrement() }
                        await self.handleTCP(channel: child)
                    }
                }
            }
        }
    }

    public func stop() async throws {}
}
