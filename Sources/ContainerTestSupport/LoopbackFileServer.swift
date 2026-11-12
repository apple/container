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
import NIOCore
import NIOHTTP1
import NIOPosix

/// Minimal loopback-only HTTP/1.1 server that serves a single fixed byte
/// payload for any GET request. Used by integration tests that need to
/// exercise a "fetch this over a URL" code path without depending on a real
/// network peer.
public final class LoopbackFileServer: Sendable {
    /// URL clients should fetch to receive the served payload.
    public let url: URL

    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel

    public init(serving data: Data) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(StaticPayloadHandler(data: data))
                }
            }

        let channel: any Channel
        do {
            channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
        guard let port = channel.localAddress?.port else {
            try? channel.close().wait()
            try? group.syncShutdownGracefully()
            throw CommandError.executionFailed("loopback file server has no bound port")
        }

        self.group = group
        self.channel = channel
        self.url = URL(string: "http://127.0.0.1:\(port)/payload")!
    }

    /// Stops accepting connections and shuts down the server's event loop.
    public func shutdown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// Responds to any request with the fixed payload, then closes the connection.
private final class StaticPayloadHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = self.unwrapInboundIn(data) else { return }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(self.data.count)")
        headers.add(name: "Connection", value: "close")
        context.write(self.wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: self.data.count)
        buffer.writeBytes(self.data)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            loopBoundContext.value.close(promise: nil)
        }
    }
}
