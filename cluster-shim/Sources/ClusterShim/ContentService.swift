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
import GRPCCore
import SwiftProtobuf

typealias ContentAPI = Containerd_Services_Content_V1_Content

/// containerd's content service, served to containerd's proxy content plugin.
/// Behaves like containerd's own content server over its local store, with
/// `Info` and `Read` falling back to the host.
struct ContentService: ContentAPI.SimpleServiceProtocol {
    let store: TieredStore

    private static let readChunkSize = 1 << 20

    func info(
        request: Containerd_Services_Content_V1_InfoRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_InfoResponse {
        var response = Containerd_Services_Content_V1_InfoResponse()
        response.info = Self.info(try await store.info(digest: request.digest))
        return response
    }

    /// Labels are kept by containerd's metadata store, so the backend has none
    /// to update, as with containerd's local store.
    func update(
        request: Containerd_Services_Content_V1_UpdateRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_UpdateResponse {
        throw RPCError(code: .failedPrecondition, message: "update not supported on immutable content store")
    }

    func list(
        request: Containerd_Services_Content_V1_ListContentRequest,
        response: RPCWriter<Containerd_Services_Content_V1_ListContentResponse>,
        context: ServerContext
    ) async throws {
        guard request.filters.isEmpty else {
            throw RPCError(code: .unimplemented, message: "content filters are not supported")
        }
        var message = Containerd_Services_Content_V1_ListContentResponse()
        message.info = try store.local.walk().map(Self.info)
        try await response.write(message)
    }

    func delete(
        request: Containerd_Services_Content_V1_DeleteContentRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        try await store.local.delete(digest: request.digest)
        return Google_Protobuf_Empty()
    }

    func read(
        request: Containerd_Services_Content_V1_ReadContentRequest,
        response: RPCWriter<Containerd_Services_Content_V1_ReadContentResponse>,
        context: ServerContext
    ) async throws {
        let blobSize = try await store.readSize(digest: request.digest)
        let offset = max(request.offset, 0)
        guard offset <= blobSize else {
            throw RPCError(code: .outOfRange, message: "read past object length \(blobSize) bytes")
        }
        var size = request.size
        if size <= 0 || offset + size > blobSize {
            size = blobSize - offset
        }

        var position = offset
        let end = offset + size
        while position < end {
            let length = Int(min(Int64(Self.readChunkSize), end - position))
            var message = Containerd_Services_Content_V1_ReadContentResponse()
            message.offset = position
            message.data = try await store.read(digest: request.digest, offset: position, length: length)
            guard !message.data.isEmpty else {
                throw RPCError(code: .dataLoss, message: "short read of \(request.digest) at \(position)")
            }
            try await response.write(message)
            position += Int64(message.data.count)
        }
    }

    func status(
        request: Containerd_Services_Content_V1_StatusRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_StatusResponse {
        var response = Containerd_Services_Content_V1_StatusResponse()
        response.status = Self.status(try store.local.status(ref: request.ref))
        return response
    }

    func listStatuses(
        request: Containerd_Services_Content_V1_ListStatusesRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_ListStatusesResponse {
        guard request.filters.isEmpty else {
            throw RPCError(code: .unimplemented, message: "status filters are not supported")
        }
        var response = Containerd_Services_Content_V1_ListStatusesResponse()
        response.statuses = try store.local.listStatuses().map(Self.status)
        return response
    }

    /// Follows containerd's content server: the first message names the ref
    /// and opens its writer, then each message stats, writes or commits.
    func write(
        request: RPCAsyncSequence<Containerd_Services_Content_V1_WriteContentRequest, any Error>,
        response: RPCWriter<Containerd_Services_Content_V1_WriteContentResponse>,
        context: ServerContext
    ) async throws {
        var requests = request.makeAsyncIterator()
        guard var message = try await requests.next() else {
            return
        }
        guard !message.ref.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "first message must have a reference")
        }

        let ref = message.ref
        var total = message.total
        var expected = message.expected
        let writer = try await store.local.writer(ref: ref, total: total, expected: expected)
        defer { writer.close() }

        while true {
            var reply = Containerd_Services_Content_V1_WriteContentResponse()
            reply.action = message.action
            reply.offset = writer.offset

            if !message.expected.isEmpty {
                expected = message.expected
                if await exists(digest: expected) {
                    writer.close()
                    try? store.local.abort(ref: ref)
                    throw RPCError(code: .alreadyExists, message: "blob with expected digest \(expected) exists")
                }
            }
            if message.total > 0 {
                total = message.total
            }

            switch message.action {
            case .stat:
                reply.digest = writer.digest
                reply.startedAt = Google_Protobuf_Timestamp(date: writer.startedAt)
                reply.updatedAt = Google_Protobuf_Timestamp(date: writer.updatedAt)
                reply.total = total
            case .write, .commit:
                if message.offset > 0 && message.offset != writer.offset {
                    throw RPCError(code: .outOfRange, message: "write @\(message.offset) must occur at current offset \(writer.offset)")
                }
                if message.offset == 0 && writer.offset > 0 {
                    try writer.truncate()
                    reply.offset = 0
                }
                if !message.data.isEmpty {
                    try writer.write(message.data)
                    reply.offset += Int64(message.data.count)
                }
                if message.action == .commit {
                    try writer.commit(size: total, expected: expected)
                }
                reply.digest = writer.digest
            case .UNRECOGNIZED(let value):
                throw RPCError(code: .invalidArgument, message: "unknown write action \(value)")
            }

            try await response.write(reply)
            if message.action == .commit {
                return
            }
            guard let next = try await requests.next() else {
                return
            }
            message = next
        }
    }

    func abort(
        request: Containerd_Services_Content_V1_AbortRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        try store.local.abort(ref: request.ref)
        return Google_Protobuf_Empty()
    }

    /// Reports whether the tiered store has a blob. Any error counts as not
    /// having it, as in containerd's content server.
    private func exists(digest: String) async -> Bool {
        (try? await store.info(digest: digest)) != nil
    }

    private static func info(_ blob: BlobInfo) -> Containerd_Services_Content_V1_Info {
        var info = Containerd_Services_Content_V1_Info()
        info.digest = blob.digest
        info.size = blob.size
        info.createdAt = Google_Protobuf_Timestamp(date: blob.createdAt)
        info.updatedAt = Google_Protobuf_Timestamp(date: blob.updatedAt)
        return info
    }

    private static func status(_ ingest: IngestStatus) -> Containerd_Services_Content_V1_Status {
        var status = Containerd_Services_Content_V1_Status()
        status.ref = ingest.ref
        status.offset = ingest.offset
        status.total = ingest.total
        status.startedAt = Google_Protobuf_Timestamp(date: ingest.startedAt)
        status.updatedAt = Google_Protobuf_Timestamp(date: ingest.updatedAt)
        return status
    }
}
