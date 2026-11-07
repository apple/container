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
import Synchronization

@testable import ClusterShim

/// A blob in the fake content store.
struct FakeBlob: Equatable {
    var data: Data
    var labels: [String: String]
}

/// containerd's content service over an in-memory store. Write follows
/// containerd's rules: the first request names the ingest, data is written at
/// the current offset, and a commit checks the size and digest.
final class FakeContent: ContentAPI.SimpleServiceProtocol {
    let blobs: Mutex<[String: FakeBlob]>
    /// The data size of each WRITE or COMMIT request, per committed digest.
    let writes = Mutex<[String: [Int]]>([:])

    init(blobs: [String: FakeBlob] = [:]) {
        self.blobs = Mutex(blobs)
    }

    func info(
        request: Containerd_Services_Content_V1_InfoRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_InfoResponse {
        guard let blob = blobs.withLock({ $0[request.digest] }) else {
            throw RPCError(code: .notFound, message: "content \(request.digest): not found")
        }
        var response = Containerd_Services_Content_V1_InfoResponse()
        response.info.digest = request.digest
        response.info.size = Int64(blob.data.count)
        response.info.labels = blob.labels
        return response
    }

    func update(
        request: Containerd_Services_Content_V1_UpdateRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_UpdateResponse {
        try blobs.withLock { blobs in
            guard blobs[request.info.digest] != nil else {
                throw RPCError(code: .notFound, message: "content \(request.info.digest): not found")
            }
            blobs[request.info.digest]?.labels.merge(request.info.labels) { _, new in new }
        }
        return Containerd_Services_Content_V1_UpdateResponse()
    }

    func write(
        request: RPCAsyncSequence<Containerd_Services_Content_V1_WriteContentRequest, any Error>,
        response: RPCWriter<Containerd_Services_Content_V1_WriteContentResponse>,
        context: ServerContext
    ) async throws {
        var data = Data()
        var sizes: [Int] = []
        var expected = ""
        var total: Int64 = 0
        var first = true
        for try await message in request {
            if first {
                guard !message.ref.isEmpty else {
                    throw RPCError(code: .invalidArgument, message: "first message must have a reference")
                }
                first = false
            }
            if !message.expected.isEmpty {
                expected = message.expected
                if blobs.withLock({ $0[expected] }) != nil {
                    throw RPCError(code: .alreadyExists, message: "blob with expected digest \(expected) exists")
                }
            }
            if message.total > 0 {
                total = message.total
            }
            switch message.action {
            case .stat:
                break
            case .write, .commit:
                guard message.offset == Int64(data.count) else {
                    throw RPCError(code: .outOfRange, message: "write @\(message.offset) must occur at current offset \(data.count)")
                }
                data.append(message.data)
                sizes.append(message.data.count)
            case .UNRECOGNIZED(let value):
                throw RPCError(code: .invalidArgument, message: "unknown write action \(value)")
            }
            var reply = Containerd_Services_Content_V1_WriteContentResponse()
            reply.action = message.action
            reply.offset = Int64(data.count)
            try await response.write(reply)

            if message.action == .commit {
                guard Int64(data.count) == total else {
                    throw RPCError(code: .failedPrecondition, message: "unexpected commit size \(data.count), expected \(total)")
                }
                guard digest(of: data) == expected else {
                    throw RPCError(code: .failedPrecondition, message: "unexpected commit digest \(digest(of: data)), expected \(expected)")
                }
                blobs.withLock { $0[expected] = FakeBlob(data: data, labels: message.labels) }
                writes.withLock { $0[expected] = sizes }
                return
            }
        }
    }

    func list(
        request: Containerd_Services_Content_V1_ListContentRequest,
        response: RPCWriter<Containerd_Services_Content_V1_ListContentResponse>,
        context: ServerContext
    ) async throws {
        throw RPCError(code: .unimplemented, message: "list")
    }

    func delete(
        request: Containerd_Services_Content_V1_DeleteContentRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        throw RPCError(code: .unimplemented, message: "delete")
    }

    func read(
        request: Containerd_Services_Content_V1_ReadContentRequest,
        response: RPCWriter<Containerd_Services_Content_V1_ReadContentResponse>,
        context: ServerContext
    ) async throws {
        throw RPCError(code: .unimplemented, message: "read")
    }

    func status(
        request: Containerd_Services_Content_V1_StatusRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_StatusResponse {
        throw RPCError(code: .unimplemented, message: "status")
    }

    func listStatuses(
        request: Containerd_Services_Content_V1_ListStatusesRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Content_V1_ListStatusesResponse {
        throw RPCError(code: .unimplemented, message: "listStatuses")
    }

    func abort(
        request: Containerd_Services_Content_V1_AbortRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        throw RPCError(code: .unimplemented, message: "abort")
    }
}

/// containerd's images service holding image targets by name.
final class FakeImages: ImagesAPI.SimpleServiceProtocol {
    let targets = Mutex<[String: String]>([:])

    func create(
        request: Containerd_Services_Images_V1_CreateImageRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Images_V1_CreateImageResponse {
        try targets.withLock { targets in
            guard targets[request.image.name] == nil else {
                throw RPCError(code: .alreadyExists, message: "image \(request.image.name): already exists")
            }
            targets[request.image.name] = request.image.target.digest
        }
        var response = Containerd_Services_Images_V1_CreateImageResponse()
        response.image = request.image
        return response
    }

    func update(
        request: Containerd_Services_Images_V1_UpdateImageRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Images_V1_UpdateImageResponse {
        targets.withLock { $0[request.image.name] = request.image.target.digest }
        var response = Containerd_Services_Images_V1_UpdateImageResponse()
        response.image = request.image
        return response
    }

    func get(
        request: Containerd_Services_Images_V1_GetImageRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Images_V1_GetImageResponse {
        throw RPCError(code: .unimplemented, message: "get")
    }

    func list(
        request: Containerd_Services_Images_V1_ListImagesRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Images_V1_ListImagesResponse {
        throw RPCError(code: .unimplemented, message: "list")
    }

    func delete(
        request: Containerd_Services_Images_V1_DeleteImageRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        throw RPCError(code: .unimplemented, message: "delete")
    }
}

/// containerd's leases service holding the IDs of current leases and the
/// content digests added to them.
final class FakeLeases: LeasesAPI.SimpleServiceProtocol {
    let current = Mutex<Set<String>>([])
    let created = Mutex(0)
    let content = Mutex<[String: Set<String>]>([:])

    func create(
        request: Containerd_Services_Leases_V1_CreateRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Leases_V1_CreateResponse {
        current.withLock { _ = $0.insert(request.id) }
        created.withLock { $0 += 1 }
        var response = Containerd_Services_Leases_V1_CreateResponse()
        response.lease.id = request.id
        return response
    }

    func delete(
        request: Containerd_Services_Leases_V1_DeleteRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        current.withLock { _ = $0.remove(request.id) }
        return Google_Protobuf_Empty()
    }

    func list(
        request: Containerd_Services_Leases_V1_ListRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Leases_V1_ListResponse {
        throw RPCError(code: .unimplemented, message: "list")
    }

    func addResource(
        request: Containerd_Services_Leases_V1_AddResourceRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        try current.withLock { current in
            guard current.contains(request.id) else {
                throw RPCError(code: .notFound, message: "lease \(request.id): not found")
            }
        }
        guard request.resource.type == "content" else {
            throw RPCError(code: .invalidArgument, message: "unsupported resource type \(request.resource.type)")
        }
        content.withLock { _ = $0[request.id, default: []].insert(request.resource.id) }
        return Google_Protobuf_Empty()
    }

    func deleteResource(
        request: Containerd_Services_Leases_V1_DeleteResourceRequest,
        context: ServerContext
    ) async throws -> Google_Protobuf_Empty {
        throw RPCError(code: .unimplemented, message: "deleteResource")
    }

    func listResources(
        request: Containerd_Services_Leases_V1_ListResourcesRequest,
        context: ServerContext
    ) async throws -> Containerd_Services_Leases_V1_ListResourcesResponse {
        throw RPCError(code: .unimplemented, message: "listResources")
    }
}
