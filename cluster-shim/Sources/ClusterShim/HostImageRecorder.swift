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

import ContainerizationOCI
import Foundation
import GRPCCore
import SwiftProtobuf

typealias ImagesAPI = Containerd_Services_Images_V1_Images
typealias LeasesAPI = Containerd_Services_Leases_V1_Leases

/// A blob to commit in containerd, with the labels to set on it.
struct BlobCommit: Equatable {
    var descriptor: Descriptor
    var labels: [String: String]
}

/// Records host images in containerd's CRI namespace. It commits the blobs an
/// image needs for the node's platform without copying them, because
/// containerd's metadata store finds them through the tiered content store,
/// then creates the image record.
struct HostImageRecorder: Sendable {
    let host: any HostStore
    let content: any ContentAPI.ClientProtocol
    let images: any ImagesAPI.ClientProtocol
    let leases: any LeasesAPI.ClientProtocol
    let platform: Platform

    static let namespace = "k8s.io"
    static let criManagedLabel = "io.cri-containerd.image"

    func record(reference: String) async throws {
        let target = try await host.image(reference: reference)

        var leaseRequest = Containerd_Services_Leases_V1_CreateRequest()
        leaseRequest.id = "cluster-shim-\(UUID().uuidString.lowercased())"
        leaseRequest.labels = ["containerd.io/gc.expire": Self.expiry(after: 3600)]
        _ = try await leases.create(leaseRequest, metadata: Self.metadata(lease: nil))

        let leased = Self.metadata(lease: leaseRequest.id)
        do {
            for blob in try await blobCommits(for: target) {
                try await commitBlob(blob, metadata: leased)
            }
            try await createImage(reference: reference, target: target, metadata: leased)
        } catch {
            try? await deleteLease(id: leaseRequest.id)
            throw error
        }
        try await deleteLease(id: leaseRequest.id)
    }

    /// Returns the blobs to commit for `descriptor` and the children it needs
    /// for the node's platform, children first. Each index and manifest is
    /// labelled with references to its children so containerd's garbage
    /// collection keeps them.
    func blobCommits(for descriptor: Descriptor) async throws -> [BlobCommit] {
        switch descriptor.mediaType {
        case MediaTypes.index, MediaTypes.dockerManifestList:
            let index = try JSONDecoder().decode(Index.self, from: try await host.readManifest(digest: descriptor.digest))
            let matching = try filterPlatforms(matcher: createPlatformMatcher(for: platform), index.manifests)
            guard let manifest = matching.first else {
                throw RPCError(code: .notFound, message: "image index \(descriptor.digest) has no manifest for \(platform)")
            }
            var commits = try await blobCommits(for: manifest)
            commits.append(BlobCommit(descriptor: descriptor, labels: ["containerd.io/gc.ref.content.m.0": manifest.digest]))
            return commits
        case MediaTypes.imageManifest, MediaTypes.dockerManifest:
            let manifest = try JSONDecoder().decode(Manifest.self, from: try await host.readManifest(digest: descriptor.digest))
            var commits = [BlobCommit(descriptor: manifest.config, labels: [:])]
            var labels = ["containerd.io/gc.ref.content.config": manifest.config.digest]
            for (position, layer) in manifest.layers.enumerated() {
                commits.append(BlobCommit(descriptor: layer, labels: [:]))
                labels["containerd.io/gc.ref.content.l.\(position)"] = layer.digest
            }
            commits.append(BlobCommit(descriptor: descriptor, labels: labels))
            return commits
        default:
            return [BlobCommit(descriptor: descriptor, labels: [:])]
        }
    }

    /// Commits one blob. A blob the namespace already has gets its labels updated.
    private func commitBlob(_ blob: BlobCommit, metadata: Metadata) async throws {
        let request = Self.commitRequest(blob)
        do {
            try await content.write(metadata: metadata) { [request] writer in
                try await writer.write(request)
            } onResponse: { response in
                for try await _ in response.messages {}
            }
        } catch let error as RPCError where error.code == .alreadyExists {
            guard !blob.labels.isEmpty else {
                return
            }
            var update = Containerd_Services_Content_V1_UpdateRequest()
            update.info.digest = blob.descriptor.digest
            update.info.labels = blob.labels
            update.updateMask.paths = blob.labels.keys.sorted().map { "labels.\($0)" }
            _ = try await content.update(update, metadata: metadata)
        }
    }

    /// A COMMIT that opens and commits the blob's ingest at its full size.
    /// Under containerd's shared content policy the metadata store finds the
    /// blob in the tiered store, so no bytes are sent.
    static func commitRequest(_ blob: BlobCommit) -> Containerd_Services_Content_V1_WriteContentRequest {
        var request = Containerd_Services_Content_V1_WriteContentRequest()
        request.action = .commit
        request.ref = "cluster-shim-\(blob.descriptor.digest)"
        request.total = blob.descriptor.size
        request.expected = blob.descriptor.digest
        request.offset = blob.descriptor.size
        request.labels = blob.labels
        return request
    }

    /// Creates the image record, or points an existing one at the host's target.
    private func createImage(reference: String, target: Descriptor, metadata: Metadata) async throws {
        var image = Containerd_Services_Images_V1_Image()
        image.name = reference
        image.labels = [Self.criManagedLabel: "managed"]
        image.target.mediaType = target.mediaType
        image.target.digest = target.digest
        image.target.size = target.size

        var create = Containerd_Services_Images_V1_CreateImageRequest()
        create.image = image
        do {
            _ = try await images.create(create, metadata: metadata)
        } catch let error as RPCError where error.code == .alreadyExists {
            var update = Containerd_Services_Images_V1_UpdateImageRequest()
            update.image = image
            update.updateMask.paths = ["target", "labels.\(Self.criManagedLabel)"]
            _ = try await images.update(update, metadata: metadata)
        }
    }

    private func deleteLease(id: String) async throws {
        var request = Containerd_Services_Leases_V1_DeleteRequest()
        request.id = id
        _ = try await leases.delete(request, metadata: Self.metadata(lease: nil))
    }

    /// Request metadata for the CRI namespace, and a lease when given.
    static func metadata(lease: String?) -> Metadata {
        var metadata = Metadata()
        metadata.addString(namespace, forKey: "containerd-namespace")
        if let lease {
            metadata.addString(lease, forKey: "containerd-lease")
        }
        return metadata
    }

    /// An RFC 3339 time `seconds` from now, for containerd's lease expiry label.
    static func expiry(after seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
    }
}
