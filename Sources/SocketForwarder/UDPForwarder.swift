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

import Collections
import Foundation
import Logging
import NIO
import NIOFoundationCompat
import Synchronization

// Proxy backend for a single client address (clientIP, clientPort).
private final class UDPProxyBackend: ChannelInboundHandler, Sendable {
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
    private let state: Mutex<State>

    init(clientAddress: SocketAddress, serverAddress: SocketAddress, frontendChannel: any Channel, log: Logger? = nil) {
        self.clientAddress = clientAddress
        self.serverAddress = serverAddress
        self.frontendChannel = frontendChannel
        self.log = log
        let initialState = State(queuedPayloads: Deque(), channel: nil)
        self.state = Mutex(initialState)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // relay data from server to client.
        let inbound = self.unwrapInboundIn(data)
        let outbound = OutboundOut(remoteAddress: self.clientAddress, data: inbound.data)
        self.log?.trace("backend - writing datagram to client")
        _ = self.frontendChannel.writeAndFlush(outbound)
    }

    func channelActive(context: ChannelHandlerContext) {
        state.withLock {
            if !$0.queuedPayloads.isEmpty {
                self.log?.trace("backend - writing \($0.queuedPayloads.count) queued datagrams to server")
                while let queuedData = $0.queuedPayloads.popFirst() {
                    let outbound: UDPProxyBackend.OutboundOut = OutboundOut(remoteAddress: self.serverAddress, data: queuedData)
                    _ = context.channel.writeAndFlush(outbound)
                }
            }
            $0.channel = context.channel
        }
    }

    func write(data: ByteBuffer) {
        // change package remote address from proxy server to real server
        state.withLock {
            if let channel = $0.channel {
                // channel has been initialized, so relay any queued packets, along with this one to outbound
                self.log?.trace("backend - writing datagram to server")
                let outbound: UDPProxyBackend.OutboundOut = OutboundOut(remoteAddress: self.serverAddress, data: data)
                _ = channel.writeAndFlush(outbound)
            } else {
                // channel is initializing, queue
                self.log?.trace("backend - queuing datagram")
                $0.queuedPayloads.append(data)
            }
        }
    }

    func close() {
        state.withLock {
            guard let channel = $0.channel else {
                self.log?.warning("backend - close on inactive channel")
                return
            }
            _ = channel.close()
        }
    }
}

private struct ProxyContext {
    public let proxy: UDPProxyBackend
    public let closeFuture: EventLoopFuture<Void>
}

private final class UDPProxyFrontend: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    private let maxProxies = UInt(256)

    private let proxyAddress: SocketAddress
    private let serverAddress: SocketAddress
    private let eventLoopGroup: any EventLoopGroup
    private let log: Logger?

    private let proxies: Mutex<LRUCache<String, ProxyContext>>

    init(proxyAddress: SocketAddress, serverAddress: SocketAddress, eventLoopGroup: any EventLoopGroup, log: Logger? = nil) {
        self.proxyAddress = proxyAddress
        self.serverAddress = serverAddress
        self.eventLoopGroup = eventLoopGroup
        self.proxies = Mutex(LRUCache(size: maxProxies))
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
            try proxies.withLock {
                if let context = $0.get(key) {
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
                    let proxyToServerFuture = DatagramBootstrap(group: self.eventLoopGroup)
                        .channelInitializer {
                            self.log?.trace("frontend - initializing backend")
                            return $0.pipeline.addHandler(proxy)
                        }
                        .bind(to: proxyAddress)
                        .flatMap { $0.closeFuture }
                    let context = ProxyContext(proxy: proxy, closeFuture: proxyToServerFuture)
                    if let (_, evictedContext) = $0.put(key: key, value: context) {
                        self.log?.trace("frontend - closing evicted backend")
                        evictedContext.proxy.close()
                    }

                    proxy.write(data: inbound.data)
                }
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
        let proxyToServerHandler = UDPProxyFrontend(
            proxyAddress: proxyAddress,
            serverAddress: serverAddress,
            eventLoopGroup: self.eventLoopGroup,
            log: log
        )
        let bootstrap = DatagramBootstrap(group: self.eventLoopGroup)
            .channelInitializer { serverChannel in
                self.log?.trace("frontend - initializing channel")
                return serverChannel.pipeline.addHandler(proxyToServerHandler)
            }
        return
            bootstrap
            .bind(to: proxyAddress)
            .flatMap { $0.eventLoop.makeSucceededFuture(SocketForwarderResult(channel: $0)) }
    }
}
