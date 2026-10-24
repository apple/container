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
import ContainerizationOCI
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
}
