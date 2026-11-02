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

import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import Testing

@testable import ContainerImagesService

struct LegacyImageReferenceTests {
    private let fullyQualified = "docker.io/library/finlay-ledger:latest"
    private let legacy = "finlay-ledger:latest"

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: character, count: 64)
    }

    private func descriptor(_ digest: String, name: String) -> Descriptor {
        Descriptor(
            mediaType: MediaTypes.index,
            digest: digest,
            size: 1,
            annotations: [
                AnnotationKeys.containerizationImageName: name,
                AnnotationKeys.containerdImageName: fullyQualified,
            ]
        )
    }

    private func withStore(
        _ body: (ImagesService, ImageStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let contentStore = try LocalContentStore(path: root.appendingPathComponent("content"))
        let imageStore = try ImageStore(path: root, contentStore: contentStore)
        let unpack: SnapshotStore.UnpackStrategy = { _, _ in nil }
        let snapshotStore = try SnapshotStore(path: root, unpackStrategy: unpack, log: nil)
        let service = try ImagesService(
            contentStore: contentStore,
            imageStore: imageStore,
            snapshotStore: snapshotStore,
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: "test")
        )
        try await body(service, imageStore)
    }

    private func store(reference: String, digest: String, in imageStore: ImageStore) async throws {
        try await imageStore.create(
            description: Containerization.Image.Description(
                reference: reference,
                descriptor: descriptor(digest, name: reference)
            )
        )
    }

    /// A complete scratch image layout: config and manifest blobs, with no layers.
    private func withArchive(
        references: [String],
        byDigest: Bool = false,
        _ body: (URL, String) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = root.appendingPathComponent("layout")
        let blobs = layout.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        func blob(_ json: String, mediaType: String) throws -> [String: Any] {
            let data = Data(json.utf8)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: blobs.appendingPathComponent(hash))
            return ["mediaType": mediaType, "digest": "sha256:\(hash)", "size": data.count]
        }
        let config = try blob(
            #"{"architecture":"arm64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":[]}}"#,
            mediaType: "application/vnd.oci.image.config.v1+json")
        let manifestData = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2, "mediaType": MediaTypes.imageManifest, "config": config, "layers": [],
            ], options: [.sortedKeys])
        var manifest = try blob(String(decoding: manifestData, as: UTF8.self), mediaType: MediaTypes.imageManifest)
        manifest["platform"] = ["architecture": "arm64", "os": "linux"]
        let indexData = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2, "mediaType": MediaTypes.index, "manifests": [manifest],
            ], options: [.sortedKeys])
        let index = try blob(String(decoding: indexData, as: UTF8.self), mediaType: MediaTypes.index)
        let indexDigest = try #require(index["digest"] as? String)
        let manifests = references.map { name in
            let reference = byDigest ? "\(name)@\(indexDigest)" : name
            var descriptor = index
            descriptor["annotations"] = [
                AnnotationKeys.containerizationImageName: reference,
                AnnotationKeys.containerdImageName: reference,
                "org.opencontainers.image.ref.name": reference,
            ]
            return descriptor
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "manifests": manifests])
            .write(to: layout.appendingPathComponent("index.json"))
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8).write(to: layout.appendingPathComponent("oci-layout"))
        let archive = root.appendingPathComponent("image.tar")
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: archive)
        try writer.archiveDirectory(layout)
        try writer.finishEncoding()
        try await body(archive, indexDigest)
    }

    @Test(arguments: [false, true])
    func loadingAShortNameRetainsTheImportedImage(canonicalExists: Bool) async throws {
        try await withArchive(references: [legacy]) { archive, importedDigest in
            try await withStore { service, imageStore in
                if canonicalExists {
                    try await store(reference: fullyQualified, digest: digest("a"), in: imageStore)
                }
                let (loaded, rejected) = try await service.load(from: archive, force: false)
                #expect(rejected.isEmpty)
                #expect(loaded.map(\.reference) == [fullyQualified])
                #expect(loaded.first?.digest == importedDigest)
                let listed = try await service.list()
                #expect(listed.map(\.reference) == [fullyQualified])
                #expect(listed.first?.digest == importedDigest)
                let stored = try await imageStore.list()
                #expect(stored.map(\.reference) == [fullyQualified])
                #expect(stored.first?.digest == importedDigest)
            }
        }
    }

    @Test func loadingMultipleTagsRetainsEveryImportedTag() async throws {
        let other = "finlay-ledger:stable"
        let qualifiedOther = "docker.io/library/finlay-ledger:stable"
        try await withArchive(references: [legacy, other]) { archive, importedDigest in
            try await withStore { service, imageStore in
                try await store(reference: fullyQualified, digest: digest("a"), in: imageStore)
                try await store(reference: qualifiedOther, digest: digest("b"), in: imageStore)
                let (loaded, rejected) = try await service.load(from: archive, force: false)
                #expect(rejected.isEmpty)
                #expect(Set(loaded.map(\.reference)) == [fullyQualified, qualifiedOther])
                #expect(loaded.allSatisfy { $0.digest == importedDigest })
                let listed = try await service.list()
                #expect(Set(listed.map(\.reference)) == [fullyQualified, qualifiedOther])
                #expect(listed.allSatisfy { $0.digest == importedDigest })
            }
        }
    }

    @Test func loadingAQualifiedTagRemovesItsLegacyShadow() async throws {
        try await withArchive(references: [fullyQualified]) { archive, importedDigest in
            try await withStore { service, imageStore in
                try await store(reference: legacy, digest: digest("a"), in: imageStore)
                let (loaded, _) = try await service.load(from: archive, force: false)
                #expect(loaded.map(\.reference) == [fullyQualified])
                #expect(loaded.first?.digest == importedDigest)
                let stored = try await imageStore.list()
                #expect(stored.map(\.reference) == [fullyQualified])
                #expect(stored.first?.digest == importedDigest)
            }
        }
    }

    @Test func loadingADigestReferencePreservesItsName() async throws {
        try await withArchive(references: ["finlay-ledger"], byDigest: true) { archive, importedDigest in
            let reference = "finlay-ledger@\(importedDigest)"
            try await withStore { service, imageStore in
                let (loaded, _) = try await service.load(from: archive, force: false)
                #expect(loaded.map(\.reference) == [reference])
                #expect(loaded.first?.digest == importedDigest)
                let listed = try await service.list()
                #expect(listed.map(\.reference) == [reference])
            }
        }
    }

    @Test func rebuildReplacesTheLegacyShortName() async throws {
        try await withStore { service, imageStore in
            let legacyDigest = digest("a")
            let rebuiltDigest = digest("b")
            try await store(reference: legacy, digest: legacyDigest, in: imageStore)
            try await store(reference: "build-result:latest", digest: rebuiltDigest, in: imageStore)

            let tagged = try await service.tag(old: "build-result:latest", new: legacy)

            #expect(tagged.reference == fullyQualified)
            #expect(tagged.digest == rebuiltDigest)
            let listed = try await service.list()
            #expect(Set(listed.map(\.reference)) == ["build-result:latest", fullyQualified])
            #expect(listed.first { $0.reference == fullyQualified }?.digest == rebuiltDigest)
        }
    }

    @Test func taggingTheShortNameNormalizesItInPlace() async throws {
        try await withStore { service, imageStore in
            let legacyDigest = digest("c")
            try await store(reference: legacy, digest: legacyDigest, in: imageStore)

            let tagged = try await service.tag(old: legacy, new: legacy)

            #expect(tagged.reference == fullyQualified)
            #expect(tagged.digest == legacyDigest)
            let listed = try await service.list()
            #expect(listed.map(\.reference) == [fullyQualified])
            #expect(listed.first?.digest == legacyDigest)
        }
    }

    @Test func listingDropsAShortNameShadowedByARebuild() async throws {
        try await withStore { service, imageStore in
            try await store(reference: legacy, digest: digest("a"), in: imageStore)
            try await store(reference: fullyQualified, digest: digest("b"), in: imageStore)

            let listed = try await service.list()

            #expect(listed.map(\.reference) == [fullyQualified])
            #expect(listed.first?.digest == digest("b"))
        }
    }

    @Test func listingKeepsAShortNameUntilItIsRebuilt() async throws {
        try await withStore { service, imageStore in
            try await store(reference: legacy, digest: digest("a"), in: imageStore)
            try await store(reference: "ghcr.io/example/other:latest", digest: digest("d"), in: imageStore)

            let listed = try await service.list()

            #expect(Set(listed.map(\.reference)) == [legacy, "ghcr.io/example/other:latest"])
        }
    }

    @Test func listingKeepsDigestReferencesAlongsideTheirQualifiedForms() async throws {
        try await withStore { service, imageStore in
            let referenceDigest = digest("e")
            let shortDigest = "finlay-ledger@\(referenceDigest)"
            let fullyQualifiedDigest = "docker.io/library/finlay-ledger@\(referenceDigest)"
            try await store(reference: shortDigest, digest: referenceDigest, in: imageStore)
            try await store(reference: fullyQualifiedDigest, digest: referenceDigest, in: imageStore)

            let listed = try await service.list()

            #expect(Set(listed.map(\.reference)) == [shortDigest, fullyQualifiedDigest])
        }
    }
}
