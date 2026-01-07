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

import Collections
import Foundation
import Logging
import NIO
import NIOFoundationCompat
import Synchronization

// Proxy backend for a single client address (clientIP, clientPort).
private final class UDPProxyBackend: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private struct State {
        var queuedPayloads: Deque<ByteBuffer>
        var channel: (any Channel)?
    }

    private let clientAddress: SocketAddress
    private let serverAddress: SocketAddress
    private let frontendChannel: any Channel
    private let log: Logger?
    private var state: State

    init(clientAddress: SocketAddress, serverAddress: SocketAddress, frontendChannel: any Channel, log: Logger? = nil) {
        self.clientAddress = clientAddress
        self.serverAddress = serverAddress
        self.frontendChannel = frontendChannel
        self.log = log
        let initialState = State(queuedPayloads: Deque(), channel: nil)
        self.state = initialState
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // relay data from server to client.
        let inbound = self.unwrapInboundIn(data)
        let outbound = OutboundOut(remoteAddress: self.clientAddress, data: inbound.data)
        self.log?.trace("backend - writing datagram to client")
        self.frontendChannel.writeAndFlush(outbound, promise: nil)
    }

    func channelActive(context: ChannelHandlerContext) {
        if !state.queuedPayloads.isEmpty {
            self.log?.trace("backend - writing \(state.queuedPayloads.count) queued datagrams to server")
            while let queuedData = state.queuedPayloads.popFirst() {
                let outbound: UDPProxyBackend.OutboundOut = OutboundOut(remoteAddress: self.serverAddress, data: queuedData)
                context.channel.writeAndFlush(outbound, promise: nil)
            }
        }
        state.channel = context.channel
    }

    func write(data: ByteBuffer) {
        // change package remote address from proxy server to real server
        if let channel = state.channel {
            // channel has been initialized, so relay any queued packets, along with this one to outbound
            self.log?.trace("backend - writing datagram to server")
            let outbound: UDPProxyBackend.OutboundOut = OutboundOut(remoteAddress: self.serverAddress, data: data)
            channel.writeAndFlush(outbound, promise: nil)
        } else {
            // channel is initializing, queue
            self.log?.trace("backend - queuing datagram")
            state.queuedPayloads.append(data)
        }
    }

    func close() {
        guard let channel = state.channel else {
            self.log?.warning("backend - close on inactive channel")
            return
        }
        _ = channel.close()
    }
}

private struct ProxyContext {
    public let proxy: UDPProxyBackend
    public let closeFuture: EventLoopFuture<Void>
}

private final class UDPProxyFrontend: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    private let maxProxies = UInt(256)

    private let proxyAddress: SocketAddress
    private let serverAddress: SocketAddress
    private let log: Logger?

    private var proxies: LRUCache<String, ProxyContext>

    init(proxyAddress: SocketAddress, serverAddress: SocketAddress, log: Logger? = nil) {
        self.proxyAddress = proxyAddress
        self.serverAddress = serverAddress
        self.proxies = LRUCache(size: maxProxies)
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = self.unwrapInboundIn(data)

        guard let clientIP = inbound.remoteAddress.ipAddress else {
            log?.error("frontend - no client IP address in inbound payload")
            return
        }

        guard let clientPort = inbound.remoteAddress.port else {
            log?.error("frontend - no client port in inbound payload")
            return
        }

        let key = "\(clientIP):\(clientPort)"
        do {
            if let context = proxies.get(key) {
                context.proxy.write(data: inbound.data)
            } else {
                self.log?.trace("frontend - creating backend")
                let proxy = UDPProxyBackend(
                    clientAddress: inbound.remoteAddress,
                    serverAddress: self.serverAddress,
                    frontendChannel: context.channel,
                    log: log
                )
                let proxyAddress = try SocketAddress(ipAddress: "0.0.0.0", port: 0)
                let loopBoundProxy = NIOLoopBound(proxy, eventLoop: context.eventLoop)
                let proxyToServerFuture = DatagramBootstrap(group: context.eventLoop)
                    .channelInitializer { [log] channel in
                        log?.trace("frontend - initializing backend")
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(loopBoundProxy.value)
                        }
                    }
                    .bind(to: proxyAddress)
                    .flatMap { $0.closeFuture }
                let context = ProxyContext(proxy: proxy, closeFuture: proxyToServerFuture)
                if let (_, evictedContext) = proxies.put(key: key, value: context) {
                    self.log?.trace("frontend - closing evicted backend")
                    evictedContext.proxy.close()
                }

                proxy.write(data: inbound.data)
            }
        } catch {
            log?.error("server handler - backend channel creation failed with error: \(error)")
            return
        }
    }
}

public struct UDPForwarder: SocketForwarder {
    private let proxyAddress: SocketAddress

    private let serverAddress: SocketAddress

    private let eventLoopGroup: any EventLoopGroup

    private let log: Logger?

    public init(
        proxyAddress: SocketAddress,
        serverAddress: SocketAddress,
        eventLoopGroup: any EventLoopGroup,
        log: Logger? = nil
    ) throws {
        self.proxyAddress = proxyAddress
        self.serverAddress = serverAddress
        self.eventLoopGroup = eventLoopGroup
        self.log = log
    }

    public func run() throws -> EventLoopFuture<SocketForwarderResult> {
        self.log?.trace("frontend - creating channel")
        let bootstrap = DatagramBootstrap(group: self.eventLoopGroup)
            .channelInitializer { serverChannel in
                self.log?.trace("frontend - initializing channel")
                let proxyToServerHandler = UDPProxyFrontend(
                    proxyAddress: proxyAddress,
                    serverAddress: serverAddress,
                    log: log
                )
                return serverChannel.eventLoop.makeCompletedFuture {
                    try serverChannel.pipeline.syncOperations.addHandler(proxyToServerHandler)
                }
            }
        return
            bootstrap
            .bind(to: proxyAddress)
            .map { SocketForwarderResult(channel: $0) }
    }
}
