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
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerImagesService

struct ImageImporterTests {
    /// Build a single-layer image from a rootfs directory and verify that the synthesized index,
    /// manifest, and config blobs are well-formed and reference one another correctly.
    @Test
    func testBuildImageProducesSingleLayerImage() throws {
        let fm = FileManager.default

        // Create a small root filesystem to import.
        let rootfs = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: rootfs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rootfs) }
        try "hello from imported rootfs\n".write(to: rootfs.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        // Ingest directory where the OCI blobs will be written.
        let ingestDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: ingestDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ingestDir) }

        let platform = Platform(arch: "arm64", os: "linux")
        let description = try ImageImporter.buildImage(
            rootfs: rootfs,
            reference: "example.com/imported:latest",
            platform: platform,
            ingestDir: ingestDir
        )

        // The top-level descriptor must be an OCI index.
        #expect(description.reference == "example.com/imported:latest")
        #expect(description.descriptor.mediaType == MediaTypes.index)

        // Decode the index and follow it down to the manifest.
        let index: Index = try LocalContent(path: blobURL(ingestDir, description.descriptor.digest)).decode()
        #expect(index.manifests.count == 1)
        let manifestDescriptor = index.manifests[0]
        #expect(manifestDescriptor.mediaType == MediaTypes.imageManifest)
        #expect(manifestDescriptor.platform?.architecture == "arm64")
        #expect(manifestDescriptor.platform?.os == "linux")

        let manifest: Manifest = try LocalContent(path: blobURL(ingestDir, manifestDescriptor.digest)).decode()
        #expect(manifest.config.mediaType == MediaTypes.imageConfig)
        #expect(manifest.layers.count == 1)
        #expect(manifest.layers[0].mediaType == MediaTypes.imageLayerGzip)
        #expect(manifest.layers[0].size > 0)

        // The config must declare exactly one diffID matching the single layer, and carry platform info.
        let config: ContainerizationOCI.Image = try LocalContent(path: blobURL(ingestDir, manifest.config.digest)).decode()
        #expect(config.architecture == "arm64")
        #expect(config.os == "linux")
        #expect(config.rootfs.type == "layers")
        #expect(config.rootfs.diffIDs.count == 1)
        #expect(config.rootfs.diffIDs[0].hasPrefix("sha256:"))

        // Every referenced blob must actually exist in the ingest directory.
        for digest in [description.descriptor.digest, manifestDescriptor.digest, manifest.config.digest, manifest.layers[0].digest] {
            #expect(fm.fileExists(atPath: blobURL(ingestDir, digest).path))
        }
    }

    private func blobURL(_ ingestDir: URL, _ digest: String) -> URL {
        ingestDir.appendingPathComponent(digest.trimmingDigestPrefix)
    }
}
