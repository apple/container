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

struct TCPEchoServer: Sendable {
    private let serverAddress: SocketAddress

    private let eventLoopGroup: MultiThreadedEventLoopGroup

    public init(serverAddress: SocketAddress, eventLoopGroup: MultiThreadedEventLoopGroup) {
        self.serverAddress = serverAddress
        self.eventLoopGroup = eventLoopGroup
    }

    public func run() throws -> EventLoopFuture<any Channel> {
        let bootstrap = ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        BackPressureHandler()
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        TCPEchoHandler()
                    )
                }
            }

        return bootstrap.bind(to: self.serverAddress)
    }
}
