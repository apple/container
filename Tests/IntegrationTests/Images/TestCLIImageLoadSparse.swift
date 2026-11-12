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

import ContainerTestSupport
import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation
import SystemPackage
import Testing

/// Tests for loading image archives whose index lists platforms that the archive does not carry,
/// such as an archive written by an engine that keeps the full index of an image it pulled for one
/// platform. Loading one should leave the image the same way pulling one platform does: the index
/// is kept as it is, and only the content that is present is stored and usable.
@Suite
struct TestCLIImageLoadSparse {
    private var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    /// The platforms that the archives made by makeSparseArchive list but do not carry.
    private let absentPlatforms = [
        ContainerizationOCI.Platform(arch: "s390x", os: "linux"),
        ContainerizationOCI.Platform(arch: "ppc64le", os: "linux"),
    ]

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Makes an OCI image layout archive for `reference` whose index lists platforms that the archive
    /// does not carry. The archive is built from a single-platform archive of a warmup image, and
    /// the absent platforms are made up, so no store can already have their content.
    ///
    /// - Parameter includeNative: Whether the archive carries the image for the host platform.
    private func makeSparseArchive(_ f: ContainerFixture, reference: String, includeNative: Bool) throws -> FilePath {
        let source = try f.copyWarmupImage(.alpine320)
        let base = f.testDir.appending("base-\(UUID().uuidString).tar")
        try f.run(["image", "save", "--platform", "linux/\(hostArchitecture)", "--output", base.string, source]).check()

        let layout = f.testDir.appending("layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: layout.string, withIntermediateDirectories: true)
        let reader = try ArchiveReader(file: URL(filePath: base.string))
        let rejected = try reader.extractContents(to: URL(filePath: layout.string))
        #expect(rejected.isEmpty, "unexpected rejected members \(rejected)")

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let indexFile = URL(filePath: layout.appending("index.json").string)
        var top = try decoder.decode(Index.self, from: Data(contentsOf: indexFile))
        let saved = try #require(top.manifests.first, "the saved archive has no image")
        let blobs = layout.appending("blobs/sha256")
        let rootBlob = URL(filePath: blobs.appending(try #require(saved.digest.split(separator: ":").last).description).string)
        var root = try decoder.decode(Index.self, from: Data(contentsOf: rootBlob))

        let native = root.manifests.filter { $0.platform?.architecture == hostArchitecture && $0.platform?.os == "linux" }
        #expect(native.count == 1, "expected one native platform in the saved index, got \(root.manifests)")
        root.manifests = includeNative ? native : []
        for platform in absentPlatforms {
            let digest = "sha256:" + sha256(Data("\(f.testID)-\(platform.description)".utf8))
            root.manifests.append(
                Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: 482, platform: platform))
            // An attestation manifest for the absent platform, which has the platform unknown/unknown.
            root.manifests.append(
                Descriptor(
                    mediaType: MediaTypes.imageManifest,
                    digest: "sha256:" + sha256(Data("\(f.testID)-attestation-\(platform.description)".utf8)),
                    size: 838,
                    annotations: ["vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": digest],
                    platform: ContainerizationOCI.Platform(arch: "unknown", os: "unknown")))
        }

        let rootData = try encoder.encode(root)
        let rootDigest = sha256(rootData)
        try FileManager.default.removeItem(at: rootBlob)
        try rootData.write(to: URL(filePath: blobs.appending(rootDigest).string))

        var annotations = saved.annotations ?? [:]
        for key in ["com.apple.containerization.image.name", "io.containerd.image.name", "org.opencontainers.image.ref.name"] {
            annotations[key] = reference
        }
        top.manifests = [
            Descriptor(mediaType: saved.mediaType, digest: "sha256:\(rootDigest)", size: Int64(rootData.count), annotations: annotations)
        ]
        try encoder.encode(top).write(to: indexFile)

        let archive = f.testDir.appending("sparse-\(UUID().uuidString).tar")
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: URL(filePath: archive.string))
        try writer.archiveDirectory(URL(filePath: layout.string))
        try writer.finishEncoding()
        return archive
    }

    @Test func testLoadSparseArchive() async throws {
        try await ContainerFixture.with { f in
            let reference = "registry.local/\(f.testID)/sparse:latest"
            let archive = try makeSparseArchive(f, reference: reference, includeNative: true)
            f.addCleanup { try? f.doRemoveImages([reference]) }

            try f.run(["image", "load", "--input", archive.string]).check("loading an archive with absent platforms failed")
            #expect(try f.isImagePresent(reference))

            // Only the platform with content is a variant of the image.
            let inspected = try f.doInspectImages(reference)
            #expect(inspected.count == 1)
            let platforms = inspected[0].variants.map { "\($0.platform.os)/\($0.platform.architecture)" }
            #expect(platforms == ["linux/\(hostArchitecture)"], "variants \(platforms)")

            // The platform with content was unpacked and can run.
            let marker = "sparse-\(f.testID)"
            let run = try f.run(["run", "--rm", reference, "echo", marker]).check()
            #expect(run.output.contains(marker))
        }
    }

    @Test func testLoadArchiveWithNoPlatformPresentFails() async throws {
        try await ContainerFixture.with { f in
            let reference = "registry.local/\(f.testID)/none:latest"
            let archive = try makeSparseArchive(f, reference: reference, includeNative: false)
            f.addCleanup { try? f.doRemoveImages([reference]) }

            let result = try f.run(["image", "load", "--input", archive.string])
            #expect(result.status != 0, "expected the load to fail when no listed platform is in the archive")
            // The error names the platforms, and not only a digest.
            #expect(result.error.contains("none of the platforms"), "\(result.error)")
            for platform in absentPlatforms {
                #expect(result.error.contains(platform.description), "\(result.error)")
            }
            #expect(!(try f.isImagePresent(reference)), "a failed load must not leave the image behind")
        }
    }

    @Test func testSaveReportsOnlyPlatformsWithContent() async throws {
        try await ContainerFixture.with { f in
            let reference = "registry.local/\(f.testID)/save:latest"
            let archive = try makeSparseArchive(f, reference: reference, includeNative: true)
            f.addCleanup { try? f.doRemoveImages([reference]) }
            try f.run(["image", "load", "--input", archive.string]).check()

            // The index lists s390x, but the image has no content for it.
            let absent = absentPlatforms[0].description
            let result = try f.run(["image", "save", "--platform", absent, "--output", f.testDir.appending("save.tar").string, reference])
            #expect(result.status != 0)
            #expect(result.error.contains("has no content for platform \(absent)"), "\(result.error)")
            let listed = try #require(result.error.components(separatedBy: "available platforms:").last, "\(result.error)")
            #expect(listed.contains("linux/\(hostArchitecture)"), "\(result.error)")
            for platform in absentPlatforms {
                #expect(!listed.contains(platform.description), "an absent platform was reported as available: \(result.error)")
            }

            // The platform with content can be saved.
            try f.run(["image", "save", "--platform", "linux/\(hostArchitecture)", "--output", f.testDir.appending("native.tar").string, reference]).check()
        }
    }
}
