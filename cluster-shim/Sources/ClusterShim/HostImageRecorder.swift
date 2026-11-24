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

typealias ContentAPI = Containerd_Services_Content_V1_Content
typealias ImagesAPI = Containerd_Services_Images_V1_Images
typealias LeasesAPI = Containerd_Services_Leases_V1_Leases

/// Where a blob's bytes come from when it is copied into containerd.
enum BlobSource: Equatable, Sendable {
    /// Streamed from the host store.
    case host
    /// Already read from the host store, as manifests and indexes are.
    case data(Data)
}

/// A blob to commit in containerd, with the labels to set on it.
struct BlobCommit: Equatable, Sendable {
    var descriptor: Descriptor
    var labels: [String: String]
    var source: BlobSource
}

/// Records host images in containerd's CRI namespace. It copies the blobs an
/// image needs for the node's platform from the host store into containerd's
/// content store, then creates the image record.
struct HostImageRecorder: Sendable {
    let host: any HostStore
    let content: any ContentAPI.ClientProtocol
    let images: any ImagesAPI.ClientProtocol
    let leases: any LeasesAPI.ClientProtocol
    let platform: Platform
    let recordings = SingleFlight()

    static let namespace = "k8s.io"
    static let criManagedLabel = "io.cri-containerd.image"
    /// The deepest nesting of indexes an image may have.
    static let maxIndexDepth = 8
    /// How many bytes of a blob each content write request carries.
    static let writeChunkSize = 1 << 20
    /// Bounds each containerd call other than a content write, whose length
    /// depends on the blob's size.
    static let callOptions: CallOptions = {
        var options = CallOptions.defaults
        options.timeout = .seconds(60)
        return options
    }()

    /// Records the host image `target` in containerd under `name`. Throws
    /// `.notFound` before writing to containerd when the host lacks a blob the
    /// node's platform needs and containerd does not have. A record of a name
    /// and target already being recorded waits for that record.
    func record(name: String, target: Descriptor) async throws {
        try await recordings.run(key: "\(name)@\(target.digest)") {
            try await recordOnce(name: name, target: target)
        }
    }

    /// Leases every blob before checking which ones containerd has, so garbage
    /// collection cannot remove a blob between the check and its use.
    private func recordOnce(name: String, target: Descriptor) async throws {
        let blobs = try await blobCommits(for: target)

        var leaseRequest = Containerd_Services_Leases_V1_CreateRequest()
        leaseRequest.id = "cluster-shim-\(UUID().uuidString.lowercased())"
        leaseRequest.labels = ["containerd.io/gc.expire": Self.expiry(after: 3600)]
        _ = try await leases.create(leaseRequest, metadata: Self.metadata(lease: nil), options: Self.callOptions)

        let leased = Self.metadata(lease: leaseRequest.id)
        do {
            for blob in blobs {
                try await addToLease(id: leaseRequest.id, digest: blob.descriptor.digest)
            }
            let missing = try await digestsMissingFromContainerd(blobs)
            try await requireOnHost(blobs.filter { missing.contains($0.descriptor.digest) && $0.source == .host })
            for blob in blobs {
                if missing.contains(blob.descriptor.digest) {
                    try await copyBlob(blob, metadata: leased)
                } else {
                    try await updateLabels(blob, metadata: leased)
                }
            }
            try await createImage(reference: name, target: target, metadata: leased)
        } catch {
            try? await deleteLease(id: leaseRequest.id)
            throw error
        }
        try await deleteLease(id: leaseRequest.id)
    }

    /// Returns the blobs to commit for `descriptor` and the children it needs
    /// for the node's platform, children first. Each index and manifest is
    /// labelled with references to its children so containerd's garbage
    /// collection keeps them. `depth` is the number of indexes above `descriptor`.
    func blobCommits(for descriptor: Descriptor, depth: Int = 0) async throws -> [BlobCommit] {
        guard depth <= Self.maxIndexDepth else {
            throw RPCError(code: .invalidArgument, message: "image nests more than \(Self.maxIndexDepth) indexes at \(descriptor.digest)")
        }
        switch descriptor.mediaType {
        case MediaTypes.index, MediaTypes.dockerManifestList:
            let data = try await host.readManifest(digest: descriptor.digest)
            let index = try JSONDecoder().decode(Index.self, from: data)
            let matching = try filterPlatforms(matcher: createPlatformMatcher(for: platform), index.manifests)
            guard let manifest = matching.first else {
                throw RPCError(code: .notFound, message: "image index \(descriptor.digest) has no manifest for \(platform)")
            }
            var commits = try await blobCommits(for: manifest, depth: depth + 1)
            commits.append(
                BlobCommit(descriptor: descriptor, labels: ["containerd.io/gc.ref.content.m.0": manifest.digest], source: .data(data)))
            return commits
        case MediaTypes.imageManifest, MediaTypes.dockerManifest:
            let data = try await host.readManifest(digest: descriptor.digest)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            var commits = [BlobCommit(descriptor: manifest.config, labels: [:], source: .host)]
            var labels = ["containerd.io/gc.ref.content.config": manifest.config.digest]
            for (position, layer) in manifest.layers.enumerated() {
                commits.append(BlobCommit(descriptor: layer, labels: [:], source: .host))
                labels["containerd.io/gc.ref.content.l.\(position)"] = layer.digest
            }
            commits.append(BlobCommit(descriptor: descriptor, labels: labels, source: .data(data)))
            return commits
        default:
            return [BlobCommit(descriptor: descriptor, labels: [:], source: .host)]
        }
    }

    /// Throws `.notFound` when the host store lacks one of `blobs`, and
    /// `.dataLoss` when a host blob's size differs from its descriptor's.
    private func requireOnHost(_ blobs: [BlobCommit]) async throws {
        for blob in blobs {
            let size = try await host.size(digest: blob.descriptor.digest)
            guard size == blob.descriptor.size else {
                throw RPCError(
                    code: .dataLoss,
                    message: "host blob \(blob.descriptor.digest) is \(size) bytes, descriptor says \(blob.descriptor.size)")
            }
        }
    }

    /// Returns the digests of `blobs` that containerd's CRI namespace does not have.
    private func digestsMissingFromContainerd(_ blobs: [BlobCommit]) async throws -> Set<String> {
        var missing: Set<String> = []
        for blob in blobs {
            if try await !contentExists(digest: blob.descriptor.digest, metadata: Self.metadata(lease: nil)) {
                missing.insert(blob.descriptor.digest)
            }
        }
        return missing
    }

    /// Copies one blob into containerd. A blob containerd gained since it was
    /// checked has its labels updated instead.
    private func copyBlob(_ blob: BlobCommit, metadata: Metadata) async throws {
        do {
            try await writeBlob(blob, ref: "cluster-shim-\(UUID().uuidString.lowercased())", metadata: metadata)
        } catch let error as RPCError where error.code == .alreadyExists {
            try await updateLabels(blob, metadata: metadata)
        }
    }

    private func contentExists(digest: String, metadata: Metadata) async throws -> Bool {
        var request = Containerd_Services_Content_V1_InfoRequest()
        request.digest = digest
        do {
            _ = try await content.info(request, metadata: metadata, options: Self.callOptions)
            return true
        } catch let error as RPCError where error.code == .notFound {
            return false
        }
    }

    /// Streams a blob into a containerd ingest named `ref` and commits it.
    /// containerd checks the committed size and digest against the descriptor.
    private func writeBlob(_ blob: BlobCommit, ref: String, metadata: Metadata) async throws {
        try await content.write(metadata: metadata) { writer in
            try await writer.write(Self.openRequest(blob, ref: ref))
            var pending = Data()
            var offset: Int64 = 0
            try await readPieces(of: blob) { piece in
                pending.append(piece)
                guard offset + Int64(pending.count) <= blob.descriptor.size else {
                    throw RPCError(code: .dataLoss, message: "host blob \(blob.descriptor.digest) is larger than \(blob.descriptor.size) bytes")
                }
                guard pending.count >= Self.writeChunkSize else {
                    return
                }
                try await writer.write(Self.dataRequest(offset: offset, data: pending))
                offset += Int64(pending.count)
                pending = Data()
            }
            try await writer.write(Self.commitRequest(blob, offset: offset, data: pending))
        } onResponse: { response in
            for try await _ in response.messages {}
        }
    }

    /// Passes a blob's bytes to `write`, streaming them from the host when they
    /// were not read while planning.
    private func readPieces(of blob: BlobCommit, into write: (Data) async throws -> Void) async throws {
        switch blob.source {
        case .host:
            try await host.readBlob(digest: blob.descriptor.digest, into: write)
        case .data(let data):
            try await write(data)
        }
    }

    private func updateLabels(_ blob: BlobCommit, metadata: Metadata) async throws {
        guard !blob.labels.isEmpty else {
            return
        }
        var update = Containerd_Services_Content_V1_UpdateRequest()
        update.info.digest = blob.descriptor.digest
        update.info.labels = blob.labels
        update.updateMask.paths = blob.labels.keys.sorted().map { "labels.\($0)" }
        _ = try await content.update(update, metadata: metadata, options: Self.callOptions)
    }

    /// The first request of a write: a STAT naming the ingest and the blob's
    /// size and digest.
    static func openRequest(_ blob: BlobCommit, ref: String) -> Containerd_Services_Content_V1_WriteContentRequest {
        var request = Containerd_Services_Content_V1_WriteContentRequest()
        request.action = .stat
        request.ref = ref
        request.total = blob.descriptor.size
        request.expected = blob.descriptor.digest
        return request
    }

    /// A WRITE of `data` at `offset`.
    static func dataRequest(offset: Int64, data: Data) -> Containerd_Services_Content_V1_WriteContentRequest {
        var request = Containerd_Services_Content_V1_WriteContentRequest()
        request.action = .write
        request.offset = offset
        request.data = data
        return request
    }

    /// The last request of a write: a COMMIT of the remaining `data` at `offset`,
    /// with the blob's size, digest and labels.
    static func commitRequest(_ blob: BlobCommit, offset: Int64, data: Data) -> Containerd_Services_Content_V1_WriteContentRequest {
        var request = Containerd_Services_Content_V1_WriteContentRequest()
        request.action = .commit
        request.offset = offset
        request.data = data
        request.total = blob.descriptor.size
        request.expected = blob.descriptor.digest
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
            _ = try await images.create(create, metadata: metadata, options: Self.callOptions)
        } catch let error as RPCError where error.code == .alreadyExists {
            var update = Containerd_Services_Images_V1_UpdateImageRequest()
            update.image = image
            update.updateMask.paths = ["target", "labels.\(Self.criManagedLabel)"]
            _ = try await images.update(update, metadata: metadata, options: Self.callOptions)
        }
    }

    /// Adds a blob to the lease, so garbage collection keeps it until the image
    /// record references it. The blob does not have to exist yet.
    private func addToLease(id: String, digest: String) async throws {
        var request = Containerd_Services_Leases_V1_AddResourceRequest()
        request.id = id
        request.resource.id = digest
        request.resource.type = "content"
        _ = try await leases.addResource(request, metadata: Self.metadata(lease: nil), options: Self.callOptions)
    }

    private func deleteLease(id: String) async throws {
        var request = Containerd_Services_Leases_V1_DeleteRequest()
        request.id = id
        _ = try await leases.delete(request, metadata: Self.metadata(lease: nil), options: Self.callOptions)
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
