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

import AsyncHTTPClient
import ContainerizationOCI
import Foundation
import GRPCCore
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// Reads blobs and image descriptors from the host's content store. A blob or
/// image the host does not have throws an `RPCError` with code `.notFound`.
protocol HostStore: Sendable {
    /// Returns the size of a blob, asking the host every time.
    func size(digest: String) async throws -> Int64
    /// Returns `length` bytes of a blob starting at `offset`.
    func read(digest: String, offset: Int64, length: Int) async throws -> Data
    /// Returns a whole manifest or index blob.
    func readManifest(digest: String) async throws -> Data
    /// Returns the descriptor the host image store holds for a normalized reference.
    func image(reference: String) async throws -> Descriptor
}

/// A `HostStore` over HTTP on the Unix socket served by the cluster-hoststore plugin.
///
///     HEAD /blobs/<digest>          size in Content-Length
///     GET  /blobs/<digest>          blob bytes, honours "Range: bytes=<start>-<end>"
///     GET  /images?ref=<reference>  OCI descriptor JSON
struct HTTPHostStore: HostStore {
    let socketPath: String
    let client: HTTPClient

    /// Bounds how much of a manifest or index is read.
    static let maxManifestSize = 4 << 20

    func size(digest: String) async throws -> Int64 {
        let response = try await send(.HEAD, path: "/blobs/\(digest)", headers: [:])
        guard let length = response.headers.first(name: "Content-Length"), let size = Int64(length) else {
            throw RPCError(code: .internalError, message: "host HEAD /blobs/\(digest): no Content-Length")
        }
        return size
    }

    func read(digest: String, offset: Int64, length: Int) async throws -> Data {
        var headers = HTTPHeaders()
        headers.add(name: "Range", value: "bytes=\(offset)-\(offset + Int64(length) - 1)")
        let response = try await send(.GET, path: "/blobs/\(digest)", headers: headers)
        guard response.status == .partialContent else {
            throw RPCError(code: .internalError, message: "host /blobs/\(digest): range request returned \(response.status)")
        }
        return Data(buffer: try await response.body.collect(upTo: length))
    }

    func readManifest(digest: String) async throws -> Data {
        let response = try await send(.GET, path: "/blobs/\(digest)", headers: [:])
        return Data(buffer: try await response.body.collect(upTo: Self.maxManifestSize))
    }

    func image(reference: String) async throws -> Descriptor {
        guard let query = reference.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw RPCError(code: .invalidArgument, message: "invalid reference \(reference)")
        }
        let response = try await send(.GET, path: "/images?ref=\(query)", headers: [:])
        let body = try await response.body.collect(upTo: Self.maxManifestSize)
        return try JSONDecoder().decode(Descriptor.self, from: Data(buffer: body))
    }

    /// Sends a request, mapping a 404 to `.notFound` and other HTTP statuses
    /// to `.unavailable`. Transport errors are thrown as they are.
    private func send(_ method: HTTPMethod, path: String, headers: HTTPHeaders) async throws -> HTTPClientResponse {
        guard let url = URL(httpURLWithSocketPath: socketPath, uri: path) else {
            throw RPCError(code: .internalError, message: "invalid host store path \(path)")
        }
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method
        request.headers = headers
        let response = try await client.execute(request, timeout: .seconds(60))
        switch response.status {
        case .ok, .partialContent:
            return response
        case .notFound:
            throw RPCError(code: .notFound, message: "host \(path): not found")
        default:
            throw RPCError(code: .unavailable, message: "host \(method) \(path): \(response.status)")
        }
    }
}
