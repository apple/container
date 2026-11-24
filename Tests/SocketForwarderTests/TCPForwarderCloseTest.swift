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

import NIO
import Testing

@testable import SocketForwarder

/// Tests that the TCP forwarder delivers every byte it has accepted from one side
/// before it closes the other side.
struct TCPForwarderCloseTest {
    let eventLoopGroup = MultiThreadedEventLoopGroup.singleton

    /// The backend sends a large response and closes, the way an HTTP/1.0 server
    /// does. A client that drains slowly must still receive every byte before EOF.
    @Test(.timeLimit(.minutes(1)))
    func testBackendCloseDeliversAllBytesToSlowClient() async throws {
        let payloadSize = 8 * 1024 * 1024

        let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SendThenCloseHandler(payloadSize: payloadSize))
                }
            }
            .bind(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
            .get()
        let actualServerAddress = try #require(serverChannel.localAddress)

        let forwarder = try TCPForwarder(
            proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: actualServerAddress,
            eventLoopGroup: eventLoopGroup
        )
        let forwarderResult = try await forwarder.run().get()
        let actualProxyAddress = try #require(forwarderResult.proxyAddress)

        // A small receive buffer and fixed-size reads keep the client slower than the
        // backend, so the forwarder is still holding unsent bytes when it reads the backend's FIN.
        let client = try await ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(2))
            .channelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_RCVBUF)), value: 8 * 1024)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8 * 1024))
            .connect(to: actualProxyAddress) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }

        var received = 0
        try await client.executeThenClose { inbound, _ in
            for try await chunk in inbound {
                received += chunk.readableBytes
                try await Task.sleep(for: .microseconds(200))
            }
        }

        serverChannel.eventLoop.execute { _ = serverChannel.close() }
        try await serverChannel.closeFuture.get()
        forwarderResult.close()
        try await forwarderResult.wait()

        #expect(received == payloadSize)
    }

    /// The client uploads a large body and closes. A backend that drains slowly
    /// must still receive every byte before EOF.
    @Test(.timeLimit(.minutes(1)))
    func testClientCloseDeliversAllBytesToSlowBackend() async throws {
        let payloadSize = 8 * 1024 * 1024

        // Same slow-reader setup as above, on the backend side this time.
        let server = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_RCVBUF)), value: 8 * 1024)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8 * 1024))
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        let actualServerAddress = try #require(server.channel.localAddress)

        let forwarder = try TCPForwarder(
            proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: actualServerAddress,
            eventLoopGroup: eventLoopGroup
        )
        let forwarderResult = try await forwarder.run().get()
        let actualProxyAddress = try #require(forwarderResult.proxyAddress)

        let received = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                var received = 0
                try await server.executeThenClose { connections in
                    for try await connection in connections {
                        try await connection.executeThenClose { inbound, _ in
                            for try await chunk in inbound {
                                received += chunk.readableBytes
                                try await Task.sleep(for: .microseconds(200))
                            }
                        }
                        break
                    }
                }
                return received
            }
            group.addTask {
                // Close only after the whole payload is in the kernel, so any loss is the forwarder's.
                let client = try await ClientBootstrap(group: self.eventLoopGroup)
                    .connectTimeout(.seconds(2))
                    .connect(to: actualProxyAddress)
                    .get()
                try await client.writeAndFlush(ByteBuffer(repeating: UInt8(ascii: "x"), count: payloadSize))
                try await client.close()
                return nil
            }
            var received = 0
            for try await result in group {
                if let result {
                    received = result
                }
            }
            return received
        }

        forwarderResult.close()
        try await forwarderResult.wait()

        #expect(received == payloadSize)
    }
}

/// Writes `payloadSize` bytes as soon as a client connects, then closes once the
/// write has been handed to the kernel.
private final class SendThenCloseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let payloadSize: Int

    init(payloadSize: Int) {
        self.payloadSize = payloadSize
    }

    func channelActive(context: ChannelHandlerContext) {
        let payload = ByteBuffer(repeating: UInt8(ascii: "x"), count: self.payloadSize)
        context.writeAndFlush(Self.wrapOutboundOut(payload))
            .assumeIsolated()
            .whenComplete { _ in
                context.close(promise: nil)
            }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
