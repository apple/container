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

import Foundation
import NIO
import Testing

@testable import SocketForwarder

/// Behavior of the TCP forwarder when nothing listens on the backend port yet,
/// as happens while a container is still starting (apple/container#2545).
struct TCPForwarderBackendUnavailableTest {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    /// Returns a loopback address whose port was just in use and is now closed.
    private func closedLoopbackAddress() async throws -> SocketAddress {
        let channel = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .bind(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
            .get()
        let address = try #require(channel.localAddress)
        try await channel.close()
        return address
    }

    private func startForwarder(to serverAddress: SocketAddress, connectTimeout: TimeAmount = .seconds(10)) async throws -> SocketForwarderResult {
        let forwarder = try TCPForwarder(
            proxyAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: serverAddress,
            eventLoopGroup: eventLoopGroup,
            connectTimeout: connectTimeout
        )
        return try await forwarder.run().get()
    }

    /// Connects to `address`, sends `message`, and returns the first chunk received, or nil if
    /// the connection closed before any data arrived.
    private func roundTrip(_ message: String, via address: SocketAddress) async throws -> String? {
        let handler = FirstReadHandler()
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(2))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .connect(to: address)
            .get()
        // The write fails if the forwarder already closed the connection; the read result covers that case.
        try? await channel.writeAndFlush(ByteBuffer(string: message))
        let response = try await handler.firstRead(on: channel).get()
        try? await channel.close()
        return response
    }

    @Test
    func testClientClosedPromptlyWhenBackendRefuses() async throws {
        let backendAddress = try await closedLoopbackAddress()
        let forwarderResult = try await startForwarder(to: backendAddress)
        let proxyAddress = try #require(forwarderResult.proxyAddress)

        let start = ContinuousClock.now
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .connect(to: proxyAddress)
            .get()
        try await channel.closeFuture.get()
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(500), "client close took \(elapsed)")

        forwarderResult.close()
        try await forwarderResult.wait()
    }

    @Test
    func testConnectionSucceedsOnceBackendStartsListening() async throws {
        let backendAddress = try await closedLoopbackAddress()
        let forwarderResult = try await startForwarder(to: backendAddress)
        let proxyAddress = try #require(forwarderResult.proxyAddress)

        // Backend not listening yet: the client gets an empty reply.
        #expect(try await roundTrip("early", via: proxyAddress) == nil)

        // Backend starts listening: the next connection is forwarded.
        let server = TCPEchoServer(serverAddress: backendAddress, eventLoopGroup: eventLoopGroup)
        let serverChannel = try await server.run().get()
        #expect(try await roundTrip("later", via: proxyAddress) == "later")

        serverChannel.eventLoop.execute { _ = serverChannel.close() }
        try await serverChannel.closeFuture.get()
        forwarderResult.close()
        try await forwarderResult.wait()
    }

    @Test
    func testClientDisconnectWhileBackendConnectIsPending() async throws {
        // TEST-NET-1 address: the backend connect either hangs until the timeout or fails at once,
        // depending on the host's routing. Either way the client goes away first.
        let unreachable = try SocketAddress(ipAddress: "192.0.2.1", port: 9)
        let forwarderResult = try await startForwarder(to: unreachable, connectTimeout: .milliseconds(300))
        let proxyAddress = try #require(forwarderResult.proxyAddress)

        for _ in 0..<50 {
            let channel = try? await ClientBootstrap(group: eventLoopGroup)
                .connect(to: proxyAddress)
                .get()
            try? await channel?.close()
        }

        // Let pending backend connects time out after their clients are gone.
        try await Task.sleep(for: .milliseconds(500))

        // The listener still accepts connections.
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .connect(to: proxyAddress)
            .get()
        try await channel.closeFuture.get()

        forwarderResult.close()
        try await forwarderResult.wait()
    }

    #if canImport(Darwin)
    @Test
    func testBackendBootstrapConnectsWithECNDisabled() async throws {
        // XNU reports 0 for TCP_ENABLE_ECN on any socket, so the option value can't be checked.
        // This verifies that setting it is accepted and the backend connect still works.
        let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let server = TCPEchoServer(serverAddress: serverAddress, eventLoopGroup: eventLoopGroup)
        let serverChannel = try await server.run().get()
        let actualServerAddress = try #require(serverChannel.localAddress)

        let channel = try await ConnectHandler.backendBootstrap(group: eventLoopGroup, connectTimeout: .seconds(2))
            .connect(to: actualServerAddress)
            .get()
        #expect(channel.isActive)

        try await channel.close()
        serverChannel.eventLoop.execute { _ = serverChannel.close() }
        try await serverChannel.closeFuture.get()
    }
    #endif
}

/// Completes with the first chunk read from the channel, or nil if the channel closes before any data arrives.
private final class FirstReadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    // Only touched on the channel's event loop.
    private var promise: EventLoopPromise<String?>?
    private var result: String??

    func firstRead(on channel: Channel) -> EventLoopFuture<String?> {
        channel.eventLoop.flatSubmit {
            if let result = self.result {
                return channel.eventLoop.makeSucceededFuture(result)
            }
            let promise = self.promise ?? channel.eventLoop.makePromise(of: String?.self)
            self.promise = promise
            return promise.futureResult
        }
    }

    private func resolve(_ value: String?) {
        guard result == nil else { return }
        result = .some(value)
        promise?.succeed(value)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        resolve(String(buffer: Self.unwrapInboundIn(data)))
    }

    func channelInactive(context: ChannelHandlerContext) {
        resolve(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
