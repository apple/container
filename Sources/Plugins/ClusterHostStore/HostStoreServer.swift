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

import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

typealias HTTPConnection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
typealias HTTPWriter = NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>

/// Serves host blobs and image descriptors to cluster nodes over HTTP on a Unix socket.
///
///     HEAD /blobs/<digest>          size in Content-Length
///     GET  /blobs/<digest>          blob bytes, honours "Range: bytes=<start>-[<end>]"
///     GET  /images?ref=<reference>  OCI descriptor JSON
struct HostStoreServer: Sendable {
    let containerSystemConfig: ContainerSystemConfig
    let log: Logger

    private static let chunkSize = 1 << 20
    /// Connections beyond this many are closed when accepted.
    static let maxConnections = 64
    /// A connection with no reads or writes for this long is closed.
    static let idleTimeout = TimeAmount.seconds(60)

    func run(socketPath: String) async throws {
        let server = try await Self.bind(socketPath: socketPath)
        let limit = ConnectionLimit(max: Self.maxConnections)

        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { connections in
                for try await connection in connections {
                    guard limit.acquire() else {
                        log.warning("too many connections, closing", metadata: ["max": "\(Self.maxConnections)"])
                        connection.channel.close(promise: nil)
                        continue
                    }
                    group.addTask {
                        await self.serve(connection)
                        limit.release()
                    }
                }
            }
        }
    }

    /// Binds the socket with mode 0600. The umask is set while binding so the
    /// socket is never reachable with wider permissions.
    private static func bind(socketPath: String) async throws -> NIOAsyncChannel<HTTPConnection, Never> {
        let previousUmask = umask(0o177)
        defer { umask(previousUmask) }
        let server = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        IdleStateHandler(allTimeout: idleTimeout),
                        CloseOnIdleHandler(),
                    ])
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try HTTPConnection(wrappingChannelSynchronously: channel)
                }
            }
        guard chmod(socketPath, 0o600) == 0 else {
            throw ContainerizationError(.internalError, message: "chmod \(socketPath): \(String(cString: strerror(errno)))")
        }
        return server
    }

    private func serve(_ connection: HTTPConnection) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                for try await part in inbound {
                    switch part {
                    case .head(let requestHead):
                        head = requestHead
                    case .body:
                        break
                    case .end:
                        if let head {
                            try await self.respond(to: head, outbound: outbound)
                        }
                        head = nil
                    }
                }
            }
        } catch {
            log.debug("connection closed", metadata: ["error": "\(error)"])
        }
    }

    private func respond(to request: HTTPRequestHead, outbound: HTTPWriter) async throws {
        guard let url = URLComponents(string: request.uri) else {
            try await writeStatus(.badRequest, outbound: outbound)
            return
        }

        if request.method == .GET && url.path == "/images" {
            let reference = url.queryItems?.first { $0.name == "ref" }?.value
            guard let reference, (try? Reference.parse(reference)) != nil else {
                try await writeStatus(.badRequest, outbound: outbound)
                return
            }
            try await writeImage(reference: reference, outbound: outbound)
            return
        }

        if (request.method == .GET || request.method == .HEAD) && url.path.hasPrefix("/blobs/") {
            guard let digest = try? ParsedDigest(parsing: String(url.path.dropFirst("/blobs/".count))) else {
                try await writeStatus(.badRequest, outbound: outbound)
                return
            }
            let rangeHeader = request.headers.first(name: "Range")
            try await writeBlob(digest: digest, rangeHeader: rangeHeader, includeBody: request.method == .GET, outbound: outbound)
            return
        }

        try await writeStatus(.notFound, outbound: outbound)
    }

    private func writeImage(reference: String, outbound: HTTPWriter) async throws {
        let image: ClientImage
        do {
            image = try await ClientImage.get(reference: reference, containerSystemConfig: containerSystemConfig)
        } catch {
            log.debug("image lookup failed", metadata: ["reference": "\(reference)", "error": "\(error)"])
            try await writeStatus(Self.status(for: error), outbound: outbound)
            return
        }

        let body = try JSONEncoder().encode(image.descriptor)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(body.count)")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
        try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: body))))
        try await outbound.write(.end(nil))
    }

    private func writeBlob(digest: ParsedDigest, rangeHeader: String?, includeBody: Bool, outbound: HTTPWriter) async throws {
        let found: (any Content)?
        do {
            found = try await RemoteContentStoreClient().get(digest: digest.description)
        } catch {
            log.debug("blob lookup failed", metadata: ["digest": "\(digest)", "error": "\(error)"])
            try await writeStatus(Self.status(for: error), outbound: outbound)
            return
        }
        guard let content = found else {
            try await writeStatus(.notFound, outbound: outbound)
            return
        }
        let size = try content.size()

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/octet-stream")
        let range: Range<UInt64>
        let status: HTTPResponseStatus
        if let rangeHeader {
            guard let selected = Self.byteRange(rangeHeader, size: size) else {
                try await writeStatus(.rangeNotSatisfiable, outbound: outbound)
                return
            }
            range = selected
            status = .partialContent
            headers.add(name: "Content-Range", value: "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)")
        } else {
            range = 0..<size
            status = .ok
        }
        headers.add(name: "Content-Length", value: "\(range.count)")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        guard includeBody else {
            try await outbound.write(.end(nil))
            return
        }

        // Reads through the descriptor `content` opened, the file that was sized above.
        var position = range.lowerBound
        while position < range.upperBound {
            let length = Int(min(UInt64(Self.chunkSize), range.upperBound - position))
            guard let chunk = try content.data(offset: position, length: length), !chunk.isEmpty else {
                throw ContainerizationError(
                    .internalError, message: "short read of \(digest) at \(position) of \(range.upperBound)")
            }
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: chunk))))
            position += UInt64(chunk.count)
        }
        try await outbound.write(.end(nil))
    }

    private func writeStatus(_ status: HTTPResponseStatus, outbound: HTTPWriter) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        try await outbound.write(.end(nil))
    }

    /// The response status for an error from a lookup made before the response starts.
    static func status(for error: any Error) -> HTTPResponseStatus {
        guard let error = error as? ContainerizationError else {
            return .internalServerError
        }
        switch error.code {
        case .notFound:
            return .notFound
        case .invalidArgument:
            return .badRequest
        default:
            return .internalServerError
        }
    }

    /// Returns the bytes a "bytes=<start>-[<end>]" range header selects from a blob
    /// of the given size, or nil when the header is malformed or outside the blob.
    static func byteRange(_ header: String, size: UInt64) -> Range<UInt64>? {
        guard header.hasPrefix("bytes=") else {
            return nil
        }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = UInt64(bounds[0]), start < size else {
            return nil
        }
        if bounds[1].isEmpty {
            return start..<size
        }
        guard let end = UInt64(bounds[1]), end >= start else {
            return nil
        }
        return start..<(min(end, size - 1) + 1)
    }
}

/// Counts open connections up to a maximum.
final class ConnectionLimit: Sendable {
    let max: Int
    private let open = Atomic<Int>(0)

    init(max: Int) {
        self.max = max
    }

    /// Takes a slot, or returns false when all `max` are taken.
    func acquire() -> Bool {
        guard open.add(1, ordering: .relaxed).newValue <= max else {
            open.subtract(1, ordering: .relaxed)
            return false
        }
        return true
    }

    func release() {
        open.subtract(1, ordering: .relaxed)
    }
}

/// Closes the channel when `IdleStateHandler` reports it idle.
final class CloseOnIdleHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is IdleStateHandler.IdleStateEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        context.close(promise: nil)
    }
}
