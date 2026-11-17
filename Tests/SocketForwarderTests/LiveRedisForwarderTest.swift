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

struct LiveRedisForwarderTest {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["CONTAINER_TEST_REDIS_SOCKET"] != nil),
        .timeLimit(.minutes(1)),
        arguments: ["127.0.0.1", "::1"]
    )
    func redisThroughForwarder(listenAddress: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        let socketPath = try #require(environment["CONTAINER_TEST_REDIS_SOCKET"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let forwarder = try TCPForwarder(
            proxyAddress: SocketAddress(ipAddress: listenAddress, port: 0),
            serverAddress: SocketAddress(unixDomainSocketPath: socketPath),
            eventLoopGroup: group,
            connectTimeout: .seconds(3)
        )
        let listener = try await forwarder.run().get()
        do {
            let client = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(3))
                .connect(to: #require(listener.proxyAddress)) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(
                            wrappingChannelSynchronously: channel,
                            configuration: NIOAsyncChannel.Configuration(
                                inboundType: ByteBuffer.self,
                                outboundType: ByteBuffer.self
                            )
                        )
                    }
                }
            let response = try await client.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "*1\r\n$4\r\nPING\r\n"))
                var response = ""
                for try await buffer in inbound {
                    response += String(buffer: buffer)
                    if response.contains("\r\n") { break }
                }
                return response
            }
            #expect(response == "+PONG\r\n")
        } catch {
            listener.close()
            try await listener.wait()
            try await group.shutdownGracefully()
            throw error
        }
        listener.close()
        try await listener.wait()
        try await group.shutdownGracefully()
    }
}
