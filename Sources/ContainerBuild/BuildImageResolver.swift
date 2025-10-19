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
import ContainerizationOCI
import Foundation
import GRPC
import Logging

struct BuildImageResolver: BuildPipelineHandler {
    let contentStore: ContentStore

    public init(_ contentStore: ContentStore) throws {
        self.contentStore = contentStore
    }

    func accept(_ packet: ServerStream) throws -> Bool {
        guard let imageTransfer = packet.getImageTransfer() else {
            return false
        }
        guard imageTransfer.stage() == "resolver" else {
            return false
        }
        guard imageTransfer.method() == "/resolve" else {
            return false
        }
        return true
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws {
        guard let imageTransfer = packet.getImageTransfer() else {
            throw Error.imageTransferMissing
        }
        guard let ref = imageTransfer.ref() else {
            throw Error.tagMissing
        }

        guard let platform = try imageTransfer.platform() else {
            throw Error.platformMissing
        }

        let img = try await {
            guard let img = try? await ClientImage.pull(reference: ref, platform: platform) else {
                return try await ClientImage.fetch(reference: ref, platform: platform)
            }
            return img
        }()

        let index: Index = try await img.index()
        let buildID = packet.buildID
        let platforms = index.manifests.compactMap { $0.platform }
        for pl in platforms {
            if pl == platform {
                let manifest = try await img.manifest(for: pl)
                guard let ociImage: ContainerizationOCI.Image = try await self.contentStore.get(digest: manifest.config.digest) else {
                    continue
                }
                let enc = JSONEncoder()
                let data = try enc.encode(ociImage)
                let transfer = try ImageTransfer(
                    id: imageTransfer.id,
                    digest: img.descriptor.digest,
                    ref: ref,
                    platform: platform.description,
                    data: data
                )
                var response = ClientStream()
                response.buildID = buildID
                response.imageTransfer = transfer
                response.packetType = .imageTransfer(transfer)
                sender.yield(response)
                return
            }
        }
        throw Error.unknownPlatformForImage(platform.description, ref)
    }
}

extension ImageTransfer {
    fileprivate init(id: String, digest: String, ref: String, platform: String, data: Data) throws {
        self.init()
        self.id = id
        self.tag = digest
        self.metadata = [
            "os": "linux",
            "stage": "resolver",
            "method": "/resolve",
            "ref": ref,
            "platform": platform,
        ]
        self.complete = true
        self.direction = .into
        self.data = data
    }
}

extension BuildImageResolver {
    enum Error: Swift.Error, CustomStringConvertible {
        case imageTransferMissing
        case tagMissing
        case platformMissing
        case imageNameMissing
        case imageTagMissing
        case imageNotFound
        case indexDigestMissing(String)
        case unknownRegistry(String)
        case digestIsNotIndex(String)
        case digestIsNotManifest(String)
        case unknownPlatformForImage(String, String)

        var description: String {
            switch self {
            case .imageTransferMissing:
                return "imageTransfer is missing"
            case .tagMissing:
                return "tag parameter missing in metadata"
            case .platformMissing:
                return "platform parameter missing in metadata"
            case .imageNameMissing:
                return "image name missing in $ref parameter"
            case .imageTagMissing:
                return "image tag missing in $ref parameter"
            case .imageNotFound:
                return "image not found"
            case .indexDigestMissing(let ref):
                return "index digest is missing for image: \(ref)"
            case .unknownRegistry(let registry):
                return "registry \(registry) is unknown"
            case .digestIsNotIndex(let digest):
                return "digest \(digest) is not a descriptor to an index"
            case .digestIsNotManifest(let digest):
                return "digest \(digest) is not a descriptor to a manifest"
            case .unknownPlatformForImage(let platform, let ref):
                return "platform \(platform) for image \(ref) not found"
            }
        }
    }
}
