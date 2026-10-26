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

    func run(socketPath: String) async throws {
        let server = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try HTTPConnection(wrappingChannelSynchronously: channel)
                }
            }
        guard chmod(socketPath, 0o600) == 0 else {
            throw ContainerizationError(.internalError, message: "chmod \(socketPath): \(String(cString: strerror(errno)))")
        }

        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { connections in
                for try await connection in connections {
                    group.addTask { await self.serve(connection) }
                }
            }
        }
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
            guard let reference else {
                try await writeStatus(.badRequest, outbound: outbound)
                return
            }
            try await writeImage(reference: reference, outbound: outbound)
            return
        }

        if (request.method == .GET || request.method == .HEAD) && url.path.hasPrefix("/blobs/") {
            let digest = String(url.path.dropFirst("/blobs/".count))
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

    private func writeBlob(digest: String, rangeHeader: String?, includeBody: Bool, outbound: HTTPWriter) async throws {
        let found: (any Content)?
        do {
            found = try await RemoteContentStoreClient().get(digest: digest)
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

        let file = try FileHandle(forReadingFrom: content.path)
        defer { try? file.close() }
        try file.seek(toOffset: range.lowerBound)
        var remaining = range.upperBound - range.lowerBound
        while remaining > 0 {
            guard let chunk = try file.read(upToCount: min(Self.chunkSize, Int(remaining))), !chunk.isEmpty else {
                break
            }
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: chunk))))
            remaining -= UInt64(chunk.count)
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
