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

import Logging
import NIO
import Testing

@testable import SocketForwarder

struct UDPForwarderTest {
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

    @Test
    func testUDPForwarder() async throws {
        let requestCount = 100
        var responses: [String] = []

        // bring up server on ephemeral port and get address
        let serverAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let server = UDPEchoServer(serverAddress: serverAddress, eventLoopGroup: eventLoopGroup)
        let serverChannel = try await server.run().get()
        let actualServerAddress = try #require(serverChannel.localAddress)

        // bring up proxy on ephemeral port and get address
        let proxyAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let forwarder = try UDPForwarder(
            proxyAddress: proxyAddress,
            serverAddress: actualServerAddress,
            eventLoopGroup: eventLoopGroup
        )
        let forwarderResult = try await forwarder.run().get()
        let actualProxyAddress = try #require(forwarderResult.proxyAddress)

        // send a bunch of messages and collect them
        print("testUDPForwarder: send messages")
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<requestCount {
                group.addTask {
                    var response: String = "\(i): error"
                    let channel = try await DatagramBootstrap(group: self.eventLoopGroup)
                        .connect(to: actualProxyAddress) { channel in
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

                    try await channel.executeThenClose { inbound, outbound in
                        let remoteAddress = try #require(channel.channel.remoteAddress)
                        let data = ByteBufferAllocator().buffer(string: "\(i): success-udp")
                        try await outbound.write(AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: data))
                        for try await inboundData in inbound {
                            response = String(buffer: inboundData.data)
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
        print("testUDPForwarder: close server")
        serverChannel.eventLoop.execute { _ = serverChannel.close() }
        try await serverChannel.closeFuture.get()

        print("testUDPForwarder: close forwarder")
        forwarderResult.close()
        try await forwarderResult.wait()

        // verify all expected messages
        print("testUDPForwarder: validate responses")
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
            #expect(sortedResponses[i] == "\(i): success-udp")
        }
    }
}
