//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

/// Builds a single-layer OCI image from a root filesystem tarball, analogous to `docker import`.
///
/// The input archive (a plain `.tar` or a compressed `.tar.gz`/`.tar.zst`/... archive) is treated
/// as the contents of a single image layer. The archive is normalized into a canonical, uncompressed
/// tar (to compute the layer's `diffID`) and a gzip-compressed tar (the layer blob). A minimal image
/// config, manifest, and index are synthesized and written to the content store, after which the
/// image is registered in the image store under the supplied reference.
public enum ImageImporter {
    /// Build and register a single-layer image from a filesystem tarball.
    ///
    /// - Parameters:
    ///   - tarball: Path to the rootfs archive (`.tar` or a compressed tar archive).
    ///   - reference: The fully normalized reference under which to register the new image.
    ///   - platform: The platform to associate with the image. Defaults to the current host platform.
    ///   - contentStore: The content store into which the image blobs are written.
    ///   - imageStore: The image store into which the image reference is registered.
    /// - Returns: The `Image.Description` of the newly created image.
    @discardableResult
    public static func `import`(
        tarball: URL,
        reference: String,
        platform: Platform,
        contentStore: ContentStore,
        imageStore: ImageStore
    ) async throws -> Containerization.Image.Description {
        guard FileManager.default.fileExists(atPath: tarball.path) else {
            throw ContainerizationError(.notFound, message: "tarball does not exist at path \(tarball.path)")
        }

        // Validate the reference up front so that we fail before touching the content store.
        _ = try Reference.parse(reference)

        // Extract the (possibly compressed) input archive into a scratch directory. ArchiveReader
        // auto-detects the compression filter, so this handles both `.tar` and `.tar.gz` inputs.
        let extractDir = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extractDir) }
        let reader = try ArchiveReader(file: tarball)
        let rejected = try reader.extractContents(to: extractDir)
        guard rejected.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "tarball contains invalid members: \(rejected)")
        }

        let (id, ingestDir) = try await contentStore.newIngestSession()
        let description: Containerization.Image.Description
        do {
            description = try Self.buildImage(
                rootfs: extractDir,
                reference: reference,
                platform: platform,
                ingestDir: ingestDir
            )
            _ = try await contentStore.completeIngestSession(id)
        } catch {
            try? await contentStore.cancelIngestSession(id)
            throw error
        }
        let image = try await imageStore.create(description: description)
        return image.description
    }

    /// Build the OCI blobs (layer, config, manifest, index) for a single-layer image from an
    /// extracted root filesystem directory, writing them into `ingestDir`.
    ///
    /// This is the pure, side-effect-light core of the import operation: it only writes blobs into
    /// the supplied directory and returns the resulting `Image.Description`. It does not register the
    /// image or complete any ingest session, which makes it convenient to exercise in tests.
    static func buildImage(
        rootfs: URL,
        reference: String,
        platform: Platform,
        ingestDir: URL,
        created: String = ISO8601DateFormatter().string(from: Date())
    ) throws -> Containerization.Image.Description {
        let writer = try ContentWriter(for: ingestDir)

        // 1. Canonical uncompressed tar to compute the diffID (sha256 of the uncompressed layer).
        let scratch = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let plainTar = scratch.appendingPathComponent("layer.tar")
        let plainWriter = try ArchiveWriter(format: .pax, filter: .none, file: plainTar)
        try plainWriter.archiveDirectory(rootfs)
        try plainWriter.finishEncoding()
        let diffID = try Self.digestString(of: plainTar)

        // 2. Gzip-compressed tar: this is the layer blob stored in the content store.
        let gzipTar = scratch.appendingPathComponent("layer.tar.gz")
        let gzipWriter = try ArchiveWriter(format: .pax, filter: .gzip, file: gzipTar)
        try gzipWriter.archiveDirectory(rootfs)
        try gzipWriter.finishEncoding()
        let layerResult = try writer.create(from: gzipTar)
        let layerDescriptor = Descriptor(
            mediaType: MediaTypes.imageLayerGzip,
            digest: layerResult.digest.digestString,
            size: layerResult.size
        )

        // 3. Image config referencing the layer's diffID.
        let config = ContainerizationOCI.Image(
            created: created,
            architecture: platform.architecture,
            os: platform.os,
            variant: platform.variant,
            rootfs: Rootfs(type: "layers", diffIDs: [diffID]),
            history: [
                History(created: created, createdBy: "container image import", comment: "imported from tarball", emptyLayer: false)
            ]
        )
        let configResult = try writer.create(from: config)
        let configDescriptor = Descriptor(
            mediaType: MediaTypes.imageConfig,
            digest: configResult.digest.digestString,
            size: configResult.size
        )

        // 4. Manifest tying the config and layer together.
        let manifest = Manifest(config: configDescriptor, layers: [layerDescriptor])
        let manifestResult = try writer.create(from: manifest)
        let manifestDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestResult.digest.digestString,
            size: manifestResult.size,
            platform: platform
        )

        // 5. Index referencing the manifest. This is the top-level descriptor for the image.
        let index = Index(manifests: [manifestDescriptor])
        let indexResult = try writer.create(from: index)
        let indexDescriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: indexResult.digest.digestString,
            size: indexResult.size
        )

        return Containerization.Image.Description(reference: reference, descriptor: indexDescriptor)
    }

    /// Compute the `sha256:<hex>` digest of a file by streaming it through a throwaway content writer.
    private static func digestString(of file: URL) throws -> String {
        let scratch = FileManager.default.uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let writer = try ContentWriter(for: scratch)
        let result = try writer.create(from: file)
        return result.digest.digestString
    }
}
