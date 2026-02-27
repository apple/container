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

import DNS
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import DNSServer

struct ProcessRawTest {
    @Test func testProcessRawReturnsSerializedResponse() async throws {
        let handler = HostTableResolver(hosts4: ["myhost.": IPv4("10.0.0.1")!])
        let server = DNSServer(handler: StandardQueryValidator(handler: handler))

        let query = Message(
            id: 99,
            type: .query,
            questions: [Question(name: "myhost.", type: .host)]
        )
        let responseData = try await server.processRaw(data: query.serialize())
        let response = try Message(deserialize: responseData)

        #expect(99 == response.id)
        #expect(.response == response.type)
        #expect(.noError == response.returnCode)
        #expect(1 == response.answers.count)
        let record = response.answers.first as? HostRecord<IPv4>
        #expect(IPv4("10.0.0.1") == record?.ip)
    }

    @Test func testProcessRawReturnsNxdomainForUnknownHost() async throws {
        let handler = HostTableResolver(hosts4: ["known.": IPv4("10.0.0.1")!])
        let composite = CompositeResolver(handlers: [handler, NxDomainResolver()])
        let server = DNSServer(handler: StandardQueryValidator(handler: composite))

        let query = Message(
            id: 55,
            type: .query,
            questions: [Question(name: "unknown.", type: .host)]
        )
        let responseData = try await server.processRaw(data: query.serialize())
        let response = try Message(deserialize: responseData)

        #expect(55 == response.id)
        #expect(.nonExistentDomain == response.returnCode)
        #expect(0 == response.answers.count)
    }
}

struct TCPHandleTest {
    private func makeTCPFrame(hostname: String, id: UInt16 = 1) throws -> ByteBuffer {
        let bytes = try Message(
            id: id,
            type: .query,
            questions: [Question(name: hostname, type: .host)]
        ).serialize()
        var buf = ByteBuffer()
        buf.writeInteger(UInt16(bytes.count))
        buf.writeBytes(bytes)
        return buf
    }

    @Test func testTCPRoundTrip() async throws {
        let handler = HostTableResolver(hosts4: ["tcp-test.": IPv4("5.6.7.8")!])
        let server = DNSServer(
            handler: StandardQueryValidator(handler: handler),
            tcpIdleTimeout: .seconds(2)
        )

        let listener = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(
                host: "127.0.0.1",
                port: 0
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
        let port = listener.channel.localAddress!.port!

        async let serverDone: Void = listener.executeThenClose { inbound in
            for try await child in inbound {
                await server.handleTCP(channel: child)
                break
            }
        }

        let client = try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(
                host: "127.0.0.1",
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

        var response: Message?
        try await client.executeThenClose { inbound, outbound in
            try await outbound.write(try makeTCPFrame(hostname: "tcp-test.", id: 77))
            for try await var chunk in inbound {
                // Safe in-process: the entire response will arrive in one chunk
                guard let len = chunk.readInteger(as: UInt16.self) else { break }
                guard let slice = chunk.readSlice(length: Int(len)) else { break }
                response = try Message(deserialize: Data(slice.readableBytesView))
                break
            }
        }

        try? await listener.channel.close()
        try? await serverDone

        #expect(77 == response?.id)
        #expect(.noError == response?.returnCode)
        #expect(1 == response?.answers.count)
        let record = response?.answers.first as? HostRecord<IPv4>
        #expect(IPv4("5.6.7.8") == record?.ip)
    }

    @Test func testTCPPipelinedQueries() async throws {
        let handler = HostTableResolver(hosts4: [
            "first.": IPv4("1.1.1.1")!,
            "second.": IPv4("2.2.2.2")!,
        ])
        let server = DNSServer(
            handler: StandardQueryValidator(handler: handler),
            tcpIdleTimeout: .seconds(2)
        )

        let listener = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(
                host: "127.0.0.1",
                port: 0
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
        let port = listener.channel.localAddress!.port!

        async let serverDone: Void = listener.executeThenClose { inbound in
            for try await child in inbound {
                await server.handleTCP(channel: child)
                break
            }
        }

        let client = try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(
                host: "127.0.0.1",
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

        var responses: [Message] = []
        try await client.executeThenClose { inbound, outbound in
            var combined = try makeTCPFrame(hostname: "first.", id: 10)
            combined.writeImmutableBuffer(try makeTCPFrame(hostname: "second.", id: 20))
            try await outbound.write(combined)

            var accumulator = ByteBuffer()
            for try await chunk in inbound {
                accumulator.writeImmutableBuffer(chunk)
                while accumulator.readableBytes >= 2 {
                    guard let len = accumulator.getInteger(at: accumulator.readerIndex, as: UInt16.self) else { break }
                    guard accumulator.readableBytes >= 2 + Int(len) else { break }
                    accumulator.moveReaderIndex(forwardBy: 2)
                    guard let slice = accumulator.readSlice(length: Int(len)) else { break }
                    responses.append(try Message(deserialize: Data(slice.readableBytesView)))
                }
                if responses.count == 2 { break }
            }
        }

        try? await listener.channel.close()
        try? await serverDone

        #expect(2 == responses.count)
        #expect(10 == responses[0].id)
        #expect(20 == responses[1].id)
        let a1 = responses[0].answers.first as? HostRecord<IPv4>
        let a2 = responses[1].answers.first as? HostRecord<IPv4>
        #expect(IPv4("1.1.1.1") == a1?.ip)
        #expect(IPv4("2.2.2.2") == a2?.ip)
    }

    @Test func testTCPDropsOversizedFrame() async throws {
        let handler = HostTableResolver(hosts4: ["oversize.": IPv4("1.1.1.1")!])
        let server = DNSServer(
            handler: StandardQueryValidator(handler: handler),
            tcpIdleTimeout: .seconds(2)
        )

        let listener = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)
                    )
                }
            }
        let port = listener.channel.localAddress!.port!

        async let serverDone: Void = listener.executeThenClose { inbound in
            for try await child in inbound {
                await server.handleTCP(channel: child)
                break
            }
        }

        let client = try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)
                    )
                }
            }

        var receivedChunks = 0
        do {
            try await client.executeThenClose { inbound, outbound in
                var buf = ByteBuffer()
                buf.writeInteger(UInt16(DNSServer.maxTCPMessageSize + 1))
                // The server inspects only the 2-byte length prefix before closing.
                // The payload bytes that follow are never read.
                buf.writeBytes([UInt8](repeating: 0, count: 10))
                try await outbound.write(buf)

                for try await _ in inbound {
                    receivedChunks += 1
                }
            }
        } catch {
            print("testTCPDropsOversizedFrame: connection closed with error (expected): \(error)")
        }

        try? await listener.channel.close()
        try? await serverDone

        #expect(receivedChunks == 0, "Expected server to drop connection without responding to oversized frame")
    }

    @Test func testTCPIdleTimeoutDropsConnection() async throws {
        let handler = HostTableResolver(hosts4: ["idle.": IPv4("1.1.1.1")!])
        let server = DNSServer(
            handler: StandardQueryValidator(handler: handler),
            tcpIdleTimeout: .milliseconds(100)
        )

        let listener = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)
                    )
                }
            }
        let port = listener.channel.localAddress!.port!

        async let serverDone: Void = listener.executeThenClose { inbound in
            for try await child in inbound {
                await server.handleTCP(channel: child)
                break
            }
        }

        let client = try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(inboundType: ByteBuffer.self, outboundType: ByteBuffer.self)
                    )
                }
            }

        var receivedChunks = 0
        do {
            try await client.executeThenClose { inbound, outbound in
                try await Task.sleep(for: .milliseconds(300))
                for try await _ in inbound {
                    receivedChunks += 1
                }
            }
        } catch {
            print("testTCPIdleTimeoutDropsConnection: connection closed with error (expected): \(error)")
        }

        try? await listener.channel.close()
        try? await serverDone

        #expect(receivedChunks == 0, "Expected server to drop connection due to idle timeout")
    }
}
