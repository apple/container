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
import Synchronization

/// Minimal loopback-only HTTP/1.1 server that serves a fixed byte payload.
/// Tests can enable byte-range responses, override Content-Range, or disconnect
/// mid-response without depending on a real network peer.
public final class LoopbackFileServer: Sendable {
    /// URL clients should fetch to receive the served payload.
    public let url: URL

    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let requestedRanges: RangeRecorder
    private let didShutdown = Mutex(false)

    public init(
        serving data: Data,
        supportsRanges: Bool = false,
        disconnectAfterBytes: Int? = nil,
        contentRangeOverride: String? = nil,
        responseByteLimit: Int? = nil
    ) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let requestedRanges = RangeRecorder()
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        StaticPayloadHandler(
                            data: data,
                            supportsRanges: supportsRanges,
                            disconnectAfterBytes: disconnectAfterBytes,
                            contentRangeOverride: contentRangeOverride,
                            responseByteLimit: responseByteLimit,
                            requestedRanges: requestedRanges))
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
        self.requestedRanges = requestedRanges
        self.url = URL(string: "http://127.0.0.1:\(port)/payload")!
    }

    public var rangeHeaders: [String] {
        requestedRanges.values.withLock { $0 }
    }

    public var requestCount: Int {
        requestedRanges.count.withLock { $0 }
    }

    /// Stops accepting connections and shuts down the server's event loop.
    public func shutdown() {
        let shouldShutdown = didShutdown.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
        guard shouldShutdown else { return }
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// Responds with the full payload or the requested byte range, then closes.
private final class StaticPayloadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let data: Data
    private let supportsRanges: Bool
    private let disconnectAfterBytes: Int?
    private let contentRangeOverride: String?
    private let responseByteLimit: Int?
    private let requestedRanges: RangeRecorder
    private var requestedRangeStart: Int?

    init(
        data: Data,
        supportsRanges: Bool,
        disconnectAfterBytes: Int?,
        contentRangeOverride: String?,
        responseByteLimit: Int?,
        requestedRanges: RangeRecorder
    ) {
        self.data = data
        self.supportsRanges = supportsRanges
        self.disconnectAfterBytes = disconnectAfterBytes
        self.contentRangeOverride = contentRangeOverride
        self.responseByteLimit = responseByteLimit
        self.requestedRanges = requestedRanges
    }

    func channelRead(context: ChannelHandlerContext, data nioData: NIOAny) {
        switch self.unwrapInboundIn(nioData) {
        case .head(let head):
            requestedRanges.count.withLock { $0 += 1 }
            guard let range = head.headers.first(name: "Range") else { return }
            requestedRanges.values.withLock { $0.append(range) }
            requestedRangeStart = Self.rangeStart(range)
            return
        case .body:
            return
        case .end:
            break
        }

        let responseData: Data
        let status: HTTPResponseStatus
        var headers = HTTPHeaders()
        if supportsRanges, let requestedRangeStart, requestedRangeStart >= data.count {
            responseData = Data()
            status = .rangeNotSatisfiable
            headers.add(name: "Content-Range", value: "bytes */\(data.count)")
        } else if supportsRanges, let requestedRangeStart {
            responseData = Data(data.dropFirst(requestedRangeStart).prefix(responseByteLimit ?? data.count))
            status = .partialContent
            headers.add(
                name: "Content-Range",
                value: contentRangeOverride ?? "bytes \(requestedRangeStart)-\(data.count - 1)/\(data.count)")
        } else {
            responseData = data
            status = .ok
        }
        headers.add(name: "Content-Length", value: "\(responseData.count)")
        headers.add(name: "Connection", value: "close")
        context.write(
            self.wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
            promise: nil)

        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        var buffer = context.channel.allocator.buffer(capacity: responseData.count)
        if let disconnectAfterBytes {
            buffer.writeBytes(responseData.prefix(disconnectAfterBytes))
            context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { _ in
                loopBoundContext.value.close(promise: nil)
            }
            return
        }
        buffer.writeBytes(responseData)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            loopBoundContext.value.close(promise: nil)
        }
    }

    private static func rangeStart(_ value: String) -> Int? {
        guard value.hasPrefix("bytes="), value.hasSuffix("-") else { return nil }
        return Int(value.dropFirst("bytes=".count).dropLast())
    }
}

private final class RangeRecorder: Sendable {
    let values = Mutex<[String]>([])
    let count = Mutex<Int>(0)
}
