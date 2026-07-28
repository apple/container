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

import Logging
import NIOCore
import NIOPosix

final class ConnectHandler {
    private let serverAddress: SocketAddress
    private let connectTimeout: TimeAmount
    private var log: Logger? = nil

    init(serverAddress: SocketAddress, connectTimeout: TimeAmount, log: Logger?) {
        self.serverAddress = serverAddress
        self.connectTimeout = connectTimeout
        self.log = log
    }
}

extension ConnectHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func handlerAdded(context: ChannelHandlerContext) {
        // Add logger metadata.
        self.log?[metadataKey: "proxy"] = "\(context.channel.localAddress?.description ?? "none")"
        self.log?[metadataKey: "server"] = "\(context.channel.remoteAddress?.description ?? "none")"
    }

    func channelActive(context: ChannelHandlerContext) {
        self.log?.trace("frontend - channel active, connecting to backend")
        self.connectToServer(context: context)
        context.fireChannelActive()
    }
}

extension ConnectHandler: RemovableChannelHandler {}

extension ConnectHandler {
    private func connectToServer(context: ChannelHandlerContext) {
        self.log?.trace("backend - connecting")

        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(self.connectTimeout)
            .connect(to: serverAddress)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    guard context.channel.isActive else {
                        self.log?.trace("backend - frontend channel closed, closing backend connection")
                        context.channel.close(promise: nil)
                        return
                    }
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

            // Reads were paused on the frontend channel while we waited for the backend to
            // connect. Resume both sides now that GlueHandler owns steady-state flow control.
            try context.channel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
            try peerChannel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
        } catch {
            // Close connected peer channel before closing our channel.
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)
        }
    }
}
