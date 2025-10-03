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

import ContainerClient
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import GRPC

struct BuildRemoteContentProxy: BuildPipelineHandler {
    let local: ContentStore

    public init(_ contentStore: ContentStore) throws {
        self.local = contentStore
    }

    func accept(_ packet: ServerStream) throws -> Bool {
        guard let imageTransfer = packet.getImageTransfer() else {
            return false
        }
        guard imageTransfer.stage() == "content-store" else {
            return false
        }
        return true
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws {
        guard let imageTransfer = packet.getImageTransfer() else {
            throw Error.imageTransferMissing
        }

        guard let method = imageTransfer.method() else {
            throw Error.methodMissing
        }

        switch try ContentStoreMethod(method) {
        case .info:
            try await self.info(sender, imageTransfer, packet.buildID)
        case .readerAt:
            try await self.readerAt(sender, imageTransfer, packet.buildID)
        default:
            throw Error.unknownMethod(method)
        }
    }

    func info(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer, _ buildID: String) async throws {
        let descriptor = try await local.get(digest: packet.tag)
        let size = try descriptor?.size()
        let transfer = try ImageTransfer(
            id: packet.id,
            digest: packet.tag,
            method: ContentStoreMethod.info.rawValue,
            size: size
        )
        var response = ClientStream()
        response.buildID = buildID
        response.imageTransfer = transfer
        response.packetType = .imageTransfer(transfer)
        sender.yield(response)
    }

    func readerAt(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer, _ buildID: String) async throws {
        let digest = packet.descriptor.digest
        let offset: UInt64 = packet.offset() ?? 0
        let size: Int = packet.len() ?? 0
        guard let descriptor = try await local.get(digest: digest) else {
            throw Error.contentMissing
        }
        if offset == 0 && size == 0 {  // Metadata request
            var transfer = try ImageTransfer(
                id: packet.id,
                digest: packet.tag,
                method: ContentStoreMethod.readerAt.rawValue,
                size: descriptor.size(),
                data: Data()
            )
            transfer.complete = true
            var response = ClientStream()
            response.buildID = buildID
            response.imageTransfer = transfer
            response.packetType = .imageTransfer(transfer)
            sender.yield(response)
            return
        }
        guard let data = try descriptor.data(offset: offset, length: size) else {
            throw Error.invalidOffsetSizeForContent(packet.descriptor.digest, offset, size)
        }

        let transfer = try ImageTransfer(
            id: packet.id,
            digest: packet.tag,
            method: ContentStoreMethod.readerAt.rawValue,
            size: UInt64(data.count),
            data: data
        )
        var response = ClientStream()
        response.buildID = buildID
        response.imageTransfer = transfer
        response.packetType = .imageTransfer(transfer)
        sender.yield(response)
    }

    func delete(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer) async throws {
        throw NSError(domain: "RemoteContentProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "unimplemented method \(ContentStoreMethod.delete)"])
    }

    func update(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer) async throws {
        throw NSError(domain: "RemoteContentProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "unimplemented method \(ContentStoreMethod.update)"])
    }

    func walk(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer) async throws {
        throw NSError(domain: "RemoteContentProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "unimplemented method \(ContentStoreMethod.walk)"])
    }

    enum ContentStoreMethod: String {
        case info = "/containerd.services.content.v1.Content/Info"
        case readerAt = "/containerd.services.content.v1.Content/ReaderAt"
        case delete = "/containerd.services.content.v1.Content/Delete"
        case update = "/containerd.services.content.v1.Content/Update"
        case walk = "/containerd.services.content.v1.Content/Walk"

        init(_ method: String) throws {
            guard let value = ContentStoreMethod(rawValue: method) else {
                throw Error.unknownMethod(method)
            }
            self = value
        }
    }
}

extension ImageTransfer {
    fileprivate init(id: String, digest: String, method: String, size: UInt64? = nil, data: Data = Data()) throws {
        self.init()
        self.id = id
        self.tag = digest
        self.metadata = [
            "os": "linux",
            "stage": "content-store",
            "method": method,
        ]
        if let size {
            self.metadata["size"] = String(size)
        }
        self.complete = true
        self.direction = .into
        self.data = data
    }
}

extension BuildRemoteContentProxy {
    enum Error: Swift.Error, CustomStringConvertible {
        case imageTransferMissing
        case methodMissing
        case contentMissing
        case unknownMethod(String)
        case invalidOffsetSizeForContent(String, UInt64, Int)

        var description: String {
            switch self {
            case .imageTransferMissing:
                return "imageTransfer is missing"
            case .methodMissing:
                return "method is missing in request"
            case .contentMissing:
                return "content cannot be found"
            case .unknownMethod(let m):
                return "unknown content-store method \(m)"
            case .invalidOffsetSizeForContent(let digest, let offset, let size):
                return "invalid request for content: \(digest) with offset: \(offset) size: \(size)"
            }
        }
    }

}
