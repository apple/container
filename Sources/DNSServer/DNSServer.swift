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

public struct DNSServer: @unchecked Sendable {
    public var handler: DNSHandler
    let log: Logger?

    static let maxConcurrentConnections = 128

    static let maxTCPMessageSize: UInt16 = 4096

    let tcpIdleTimeout: Duration

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
