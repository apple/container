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

struct UnixBackendForwarderTest {
    @Test(.timeLimit(.minutes(1)), arguments: ["127.0.0.1", "::1"])
    func forwardsBinaryStreamToUnixBackend(listenAddress: String) async throws {
        let path = "/tmp/cz-forward-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let serverAddress = try SocketAddress(unixDomainSocketPath: path)
        let server = try await TCPEchoServer(serverAddress: serverAddress, eventLoopGroup: group).run().get()
        let forwarder = try TCPForwarder(
            proxyAddress: SocketAddress(ipAddress: listenAddress, port: 0),
            serverAddress: serverAddress,
            eventLoopGroup: group
        )
        let listener = try await forwarder.run().get()
        do {
            let client = try await ClientBootstrap(group: group)
                .connect(to: #require(listener.proxyAddress)) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(
                            wrappingChannelSynchronously: channel,
                            configuration: NIOAsyncChannel.Configuration(inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)
                        )
                    }
                }
            let payload = ByteBuffer(bytes: (0..<(128 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
            try await client.executeThenClose { inbound, outbound in
                async let write: Void = outbound.write(payload)
                var response = ByteBuffer()
                for try await var buffer in inbound {
                    response.writeBuffer(&buffer)
                    if response.readableBytes >= payload.readableBytes { break }
                }
                try await write
                #expect(response == payload)
            }
        } catch {
            listener.close()
            try await listener.wait()
            try await server.close()
            try await group.shutdownGracefully()
            throw error
        }
        listener.close()
        try await listener.wait()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test(.timeLimit(.minutes(1)))
    func reconnectsAfterUnixBackendIsRecreated() async throws {
        let path = "/tmp/cz-recovery-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let backend = try SocketAddress(unixDomainSocketPath: path)
        let forwarder = try TCPForwarder(
            proxyAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: backend,
            eventLoopGroup: group,
            allowRemoteHalfClosure: true
        )
        let listener = try await forwarder.run().get()
        let address = try #require(listener.proxyAddress)
        var server: (any Channel)?
        do {
            for _ in 0..<3 {
                let unavailable = try await ClientBootstrap(group: group).connect(to: address).get()
                try await unavailable.closeFuture.get()
                server = try await TCPEchoServer(serverAddress: backend, eventLoopGroup: group).run().get()
                let client = try await ClientBootstrap(group: group).connect(to: address) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(
                            wrappingChannelSynchronously: channel,
                            configuration: NIOAsyncChannel.Configuration(inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)
                        )
                    }
                }
                let payload = ByteBuffer(string: "backend recovered")
                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(payload)
                    var response = ByteBuffer()
                    for try await var buffer in inbound {
                        response.writeBuffer(&buffer)
                        if response.readableBytes >= payload.readableBytes { break }
                    }
                    #expect(response == payload)
                }
                try await server?.close()
                server = nil
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            }
        } catch {
            listener.close()
            try await listener.wait()
            try await server?.close()
            try await group.shutdownGracefully()
            throw error
        }
        listener.close()
        try await listener.wait()
        try await group.shutdownGracefully()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["127.0.0.1", "::1"])
    func receivesResponseAfterClientHalfClose(listenAddress: String) async throws {
        let path = "/tmp/cz-half-close-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let serverAddress = try SocketAddress(unixDomainSocketPath: path)
        let server = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ReplyAfterEOFHandler())
                }
            }
            .bind(to: serverAddress).get()
        let forwarder = try TCPForwarder(
            proxyAddress: SocketAddress(ipAddress: listenAddress, port: 0),
            serverAddress: serverAddress,
            eventLoopGroup: group,
            allowRemoteHalfClosure: true
        )
        let listener = try await forwarder.run().get()
        do {
            let client = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .connect(to: #require(listener.proxyAddress)) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(
                            wrappingChannelSynchronously: channel,
                            configuration: NIOAsyncChannel.Configuration(inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)
                        )
                    }
                }
            let payload = ByteBuffer(string: "reply after reading EOF")
            try await client.executeThenClose { inbound, outbound in
                try await outbound.write(payload)
                try await client.channel.close(mode: .output).get()
                var response = ByteBuffer()
                for try await var buffer in inbound { response.writeBuffer(&buffer) }
                #expect(response == payload)
            }
        } catch {
            listener.close()
            try await listener.wait()
            try await server.close()
            try await group.shutdownGracefully()
            throw error
        }
        listener.close()
        try await listener.wait()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test(.timeLimit(.minutes(1)))
    func missingUnixBackendClosesFrontend() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let forwarder = try TCPForwarder(
            proxyAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0),
            serverAddress: SocketAddress(unixDomainSocketPath: "/tmp/cz-missing-\(UUID().uuidString).sock"),
            eventLoopGroup: group
        )
        let listener = try await forwarder.run().get()
        let client = try await ClientBootstrap(group: group).connect(to: #require(listener.proxyAddress)).get()
        try await client.closeFuture.get()
        listener.close()
        try await listener.wait()
        try await group.shutdownGracefully()
    }
}

private final class ReplyAfterEOFHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var buffer = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        buffer.writeBuffer(&input)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            context.writeAndFlush(wrapOutboundOut(buffer)).assumeIsolatedUnsafeUnchecked().whenComplete { _ in
                context.close(promise: nil)
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}
