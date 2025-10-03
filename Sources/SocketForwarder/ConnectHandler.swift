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
import NIOCore
import NIOPosix

final class ConnectHandler {
    private var pendingBytes: [NIOAny]
    private let serverAddress: SocketAddress
    private var log: Logger? = nil

    init(serverAddress: SocketAddress, log: Logger?) {
        self.pendingBytes = []
        self.serverAddress = serverAddress
        self.log = log
    }
}

extension ConnectHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if self.pendingBytes.isEmpty {
            self.connectToServer(context: context)
        }
        self.pendingBytes.append(data)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Add logger metadata.
        self.log?[metadataKey: "proxy"] = "\(context.channel.localAddress?.description ?? "none")"
        self.log?[metadataKey: "server"] = "\(context.channel.remoteAddress?.description ?? "none")"
    }
}

extension ConnectHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        var didRead = false

        // We are being removed, and need to deliver any pending bytes we may have if we're upgrading.
        while self.pendingBytes.count > 0 {
            let data = self.pendingBytes.removeFirst()
            context.fireChannelRead(data)
            didRead = true
        }

        if didRead {
            context.fireChannelReadComplete()
        }

        self.log?.trace("backend - removing connect handler from pipeline")
        context.leavePipeline(removalToken: removalToken)
    }
}

extension ConnectHandler {
    private func connectToServer(context: ChannelHandlerContext) {
        self.log?.trace("backend - connecting")

        ClientBootstrap(group: context.eventLoop)
            .connect(to: serverAddress)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    self.log?.trace("backend - connected")
                    self.glue(channel, context: context)
                case .failure(let error):
                    self.log?.error("backend - connect failed: \(error)")
                    context.close(promise: nil)
                    context.fireErrorCaught(error)
                }
            }
    }

    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext) {
        self.log?.trace("backend - gluing channels")

        // Now we need to glue our channel and the peer channel together.
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        do {
            try context.channel.pipeline.syncOperations.addHandler(localGlue)
            try peerChannel.pipeline.syncOperations.addHandler(peerGlue)
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
        } catch {
            // Close connected peer channel before closing our channel.
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)
        }
    }
}
