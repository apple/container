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

import ContainerResource
import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation

enum OCIImageArchive {
    static func create(
        from rootfsArchive: URL,
        in temporaryDirectory: URL,
        reference: String,
        container: ContainerSnapshot,
        sourceImage: Image
    ) throws -> URL {
        let platform = container.configuration.platform
        let process = container.configuration.initProcess
        var labels = sourceImage.config?.labels ?? [:]
        labels.merge(container.configuration.labels) { _, containerValue in containerValue }
        let imageConfig = ImageConfig(
            user: process.user.description,
            env: process.environment,
            cmd: [process.executable] + process.arguments,
            workingDir: process.workingDirectory,
            labels: labels,
            stopSignal: container.configuration.stopSignal
        )

        let layoutDirectory = temporaryDirectory.appendingPathComponent("oci-layout")
        let blobsDirectory = layoutDirectory.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        let layerDescriptor = try writeBlob(fromFile: rootfsArchive, mediaType: MediaTypes.imageLayer, into: blobsDirectory)
        let created = ISO8601DateFormatter().string(from: Date())
        let config = Image(
            created: created,
            author: sourceImage.author,
            architecture: platform.architecture,
            os: platform.os,
            osVersion: sourceImage.osVersion,
            osFeatures: sourceImage.osFeatures,
            variant: platform.variant,
            config: imageConfig,
            rootfs: Rootfs(type: "layers", diffIDs: [layerDescriptor.digest]),
            history: [History(created: created, createdBy: "container commit")]
        )
        let configDescriptor = try writeBlob(fromEncodable: config, mediaType: MediaTypes.imageConfig, into: blobsDirectory)

        let manifest = Manifest(config: configDescriptor, layers: [layerDescriptor])
        var manifestDescriptor = try writeBlob(fromEncodable: manifest, mediaType: MediaTypes.imageManifest, into: blobsDirectory)
        manifestDescriptor.annotations = [
            "org.opencontainers.image.ref.name": reference,
            "io.containerd.image.name": reference,
            "com.apple.containerization.image.name": reference,
        ]
        manifestDescriptor.platform = platform

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(["imageLayoutVersion": "1.0.0"])
            .write(to: layoutDirectory.appendingPathComponent("oci-layout"), options: .atomic)
        try encoder.encode(Index(schemaVersion: 2, manifests: [manifestDescriptor]))
            .write(to: layoutDirectory.appendingPathComponent("index.json"), options: .atomic)

        let imageArchive = temporaryDirectory.appendingPathComponent("image.tar")
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: imageArchive)
        try writer.archiveDirectory(layoutDirectory)
        try writer.finishEncoding()
        return imageArchive
    }

    private static func writeBlob(fromFile source: URL, mediaType: String, into blobsDirectory: URL) throws -> Descriptor {
        let data = try Data(contentsOf: source)
        return try writeBlob(data: data, mediaType: mediaType, into: blobsDirectory)
    }

    private static func writeBlob(fromEncodable value: some Encodable, mediaType: String, into blobsDirectory: URL) throws -> Descriptor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try writeBlob(data: encoder.encode(value), mediaType: mediaType, into: blobsDirectory)
    }

    private static func writeBlob(data: Data, mediaType: String, into blobsDirectory: URL) throws -> Descriptor {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: blobsDirectory.appendingPathComponent(digest), options: .atomic)
        return Descriptor(mediaType: mediaType, digest: "sha256:\(digest)", size: Int64(data.count))
    }
}
