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

import NIO
import Testing

@testable import SocketForwarder

struct TCPForwarderTest {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    @Test
    func testTCPForwarder() async throws {
        let requestCount = 100
        var responses: [String] = []

        // bring up server on ephemeral port and get address
        let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let server = TCPEchoServer(serverAddress: serverAddress, eventLoopGroup: eventLoopGroup)
        let serverChannel = try await server.run().get()
        let actualServerAddress = try #require(serverChannel.localAddress)

        // bring up proxy on ephemeral port and get address
        let proxyAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let forwarder = try TCPForwarder(
            proxyAddress: proxyAddress,
            serverAddress: actualServerAddress,
            eventLoopGroup: eventLoopGroup
        )
        let forwarderResult = try await forwarder.run().get()
        let actualProxyAddress = try #require(forwarderResult.proxyAddress)

        // send a bunch of messages and collect them
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<requestCount {
                group.addTask {
                    var response: String = "\(i): error"
                    let channel = try await ClientBootstrap(group: self.eventLoopGroup)
                        .connectTimeout(.seconds(2))
                        .connect(to: actualProxyAddress) { channel in
                            channel.eventLoop.makeCompletedFuture {
                                // We are using two simple handlers here to frame our messages with "\n"
                                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NewlineDelimiterCoder()))
                                try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(NewlineDelimiterCoder()))

                                return try NIOAsyncChannel(
                                    wrappingChannelSynchronously: channel,
                                    configuration: NIOAsyncChannel.Configuration(
                                        inboundType: String.self,
                                        outboundType: String.self
                                    )
                                )
                            }
                        }

                    try await channel.executeThenClose { inbound, outbound in
                        try await outbound.write("\(i): success-tcp")
                        for try await inboundData in inbound {
                            response = "\(inboundData)"
                            break
                        }
                    }

                    return response
                }
            }

            for try await response in group {
                responses.append(response)
            }
        }

        // close everything down
        print("testTCPForwarder: close server")
        serverChannel.eventLoop.execute { _ = serverChannel.close() }
        try await serverChannel.closeFuture.get()

        print("testTCPForwarder: close forwarder")
        forwarderResult.close()
        try await forwarderResult.wait()

        // verify all expected messages
        print("testTCPForwarder: validate responses")
        let sortedResponses = try responses.sorted { (a, b) in
            let aParts = a.split(separator: ":")
            let bParts = b.split(separator: ":")
            #expect(aParts.count > 1)
            #expect(bParts.count > 1)
            let aIndex = try #require(Int(aParts[0]))
            let bIndex = try #require(Int(bParts[0]))
            return aIndex < bIndex
        }
        #expect(sortedResponses.count == requestCount)
        for i in 0..<requestCount {
            #expect(sortedResponses[i] == "\(i): success-tcp")
        }
    }
}

private final class NewlineDelimiterCoder: ByteToMessageDecoder, MessageToByteEncoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String

    private let newLine = UInt8(ascii: "\n")

    init() {}

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readableBytes = buffer.readableBytesView

        guard let firstLine = readableBytes.firstIndex(of: self.newLine).map({ readableBytes[..<$0] }) else {
            return .needMoreData
        }
        buffer.moveReaderIndex(forwardBy: firstLine.count + 1)
        // Fire a read without a newline
        let data = Self.wrapInboundOut(String(buffer: ByteBuffer(firstLine)))
        context.fireChannelRead(data)
        return .continue
    }

    func encode(data: String, out: inout ByteBuffer) throws {
        out.writeString(data)
        out.writeInteger(self.newLine)
    }
}
