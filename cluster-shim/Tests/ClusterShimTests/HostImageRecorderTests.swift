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
import GRPCInProcessTransport
import Testing

@testable import ClusterShim

struct HostImageRecorderTests {
    static let config = Data(#"{"architecture":"arm64","os":"linux"}"#.utf8)
    static let layer = Data("layer".utf8)
    static let manifest = Data(
        """
        {"schemaVersion":2,"mediaType":"\(MediaTypes.imageManifest)",
         "config":{"mediaType":"\(MediaTypes.imageConfig)","digest":"\(digest(of: config))","size":\(config.count)},
         "layers":[{"mediaType":"\(MediaTypes.imageLayerGzip)","digest":"\(digest(of: layer))","size":\(layer.count)}]}
        """.utf8)
    static let index = Data(
        """
        {"schemaVersion":2,"mediaType":"\(MediaTypes.index)","manifests":[
         {"mediaType":"\(MediaTypes.imageManifest)","digest":"sha256:\(String(repeating: "a", count: 64))","size":1,
          "platform":{"architecture":"amd64","os":"linux"}},
         {"mediaType":"\(MediaTypes.imageManifest)","digest":"\(digest(of: manifest))","size":\(manifest.count),
          "platform":{"architecture":"arm64","os":"linux"}}]}
        """.utf8)

    static let configDescriptor = Descriptor(mediaType: MediaTypes.imageConfig, digest: digest(of: config), size: Int64(config.count))
    static let layerDescriptor = Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: digest(of: layer), size: Int64(layer.count))
    static let manifestDescriptor = Descriptor(mediaType: MediaTypes.imageManifest, digest: digest(of: manifest), size: Int64(manifest.count))
    static let indexDescriptor = Descriptor(mediaType: MediaTypes.index, digest: digest(of: index), size: Int64(index.count))

    static let hostBlobs = [
        digest(of: index): index,
        digest(of: manifest): manifest,
        digest(of: config): config,
        digest(of: layer): layer,
    ]

    /// Returns `levels` indexes, each holding the next, around `manifest`, and
    /// the host blobs with them.
    static func nestedIndexes(levels: Int) -> (top: Descriptor, blobs: [String: Data]) {
        var blobs = hostBlobs
        var top = manifestDescriptor
        for _ in 0..<levels {
            let index = Data(
                """
                {"schemaVersion":2,"mediaType":"\(MediaTypes.index)","manifests":[
                 {"mediaType":"\(top.mediaType)","digest":"\(top.digest)","size":\(top.size),
                  "platform":{"architecture":"arm64","os":"linux"}}]}
                """.utf8)
            blobs[digest(of: index)] = index
            top = Descriptor(mediaType: MediaTypes.index, digest: digest(of: index), size: Int64(index.count))
        }
        return (top, blobs)
    }

    /// A recorder whose containerd clients are never connected.
    func makeRecorder(blobs: [String: Data] = hostBlobs) -> HostImageRecorder {
        let host = FakeHostStore(blobs: blobs)
        let unused = GRPCClient(transport: InProcessTransport().client)
        return HostImageRecorder(
            host: host,
            content: ContentAPI.Client(wrapping: unused),
            images: ImagesAPI.Client(wrapping: unused),
            leases: LeasesAPI.Client(wrapping: unused),
            platform: Platform(arch: "arm64", os: "linux")
        )
    }

    @Test func manifestCommitsConfigAndLayersBeforeItself() async throws {
        let commits = try await makeRecorder().blobCommits(for: Self.manifestDescriptor)

        #expect(
            commits == [
                BlobCommit(descriptor: Self.configDescriptor, labels: [:], source: .host),
                BlobCommit(descriptor: Self.layerDescriptor, labels: [:], source: .host),
                BlobCommit(
                    descriptor: Self.manifestDescriptor,
                    labels: [
                        "containerd.io/gc.ref.content.config": Self.configDescriptor.digest,
                        "containerd.io/gc.ref.content.l.0": Self.layerDescriptor.digest,
                    ],
                    source: .data(Self.manifest)),
            ])
    }

    @Test func indexCommitsOnlyThePlatformManifest() async throws {
        let commits = try await makeRecorder().blobCommits(for: Self.indexDescriptor)

        #expect(commits.map(\.descriptor.digest) == [Self.configDescriptor.digest, Self.layerDescriptor.digest, Self.manifestDescriptor.digest, Self.indexDescriptor.digest])
        #expect(commits.last?.labels == ["containerd.io/gc.ref.content.m.0": Self.manifestDescriptor.digest])
    }

    @Test func indexWithoutPlatformManifestIsNotFound() async throws {
        let recorder = makeRecorder()
        let other = HostImageRecorder(
            host: recorder.host,
            content: recorder.content,
            images: recorder.images,
            leases: recorder.leases,
            platform: Platform(arch: "s390x", os: "linux")
        )

        do {
            _ = try await other.blobCommits(for: Self.indexDescriptor)
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .notFound)
        }
    }

    @Test func indexesNestedPastTheLimitAreRejected() async throws {
        let (top, blobs) = Self.nestedIndexes(levels: HostImageRecorder.maxIndexDepth + 1)

        do {
            _ = try await makeRecorder(blobs: blobs).blobCommits(for: top)
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.code == .invalidArgument)
        }
    }

    @Test func indexesNestedToTheLimitAreAccepted() async throws {
        let (top, blobs) = Self.nestedIndexes(levels: HostImageRecorder.maxIndexDepth)

        let commits = try await makeRecorder(blobs: blobs).blobCommits(for: top)

        #expect(commits.count == 3 + HostImageRecorder.maxIndexDepth)
    }

    /// Records `foo:dev` from `host` into an empty fake containerd and returns
    /// the error it fails with, and whether it left a blob or a lease behind.
    func failedRecord(host: FakeHostStore) async throws -> (error: RPCError?, changed: Bool) {
        let content = FakeContent()
        var failure: RPCError?
        var changed = true
        try await withConnectedRecorder(host: host, content: content) { recorder, _, leases in
            do {
                try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)
            } catch let error as RPCError {
                failure = error
            }
            changed = !content.blobs.withLock { $0.isEmpty } || !leases.current.withLock { $0.isEmpty }
        }
        return (failure, changed)
    }

    @Test func recordWithMissingLayerIsNotFoundBeforeChangingContainerd() async throws {
        var blobs = Self.hostBlobs
        blobs[digest(of: Self.layer)] = nil

        let result = try await failedRecord(host: FakeHostStore(blobs: blobs))

        #expect(result.error?.code == .notFound)
        #expect(!result.changed)
    }

    @Test func recordWithWrongLayerSizeIsDataLossBeforeChangingContainerd() async throws {
        var blobs = Self.hostBlobs
        blobs[digest(of: Self.layer)] = Self.layer + Data("x".utf8)

        let result = try await failedRecord(host: FakeHostStore(blobs: blobs))

        #expect(result.error?.code == .dataLoss)
        #expect(!result.changed)
    }

    @Test func recordWithoutPlatformManifestIsNotFoundBeforeChangingContainerd() async throws {
        var blobs = Self.hostBlobs
        blobs[digest(of: Self.manifest)] = nil

        let result = try await failedRecord(host: FakeHostStore(blobs: blobs))

        #expect(result.error?.code == .notFound)
        #expect(!result.changed)
    }

    /// Runs `body` with a recorder over `host` whose containerd clients reach
    /// `content`, a fresh images service and a fresh leases service.
    func withConnectedRecorder(
        host: FakeHostStore,
        content: FakeContent,
        _ body: (HostImageRecorder, FakeImages, FakeLeases) async throws -> Void
    ) async throws {
        let images = FakeImages()
        let leases = FakeLeases()
        try await withInProcessServer(services: [content, images, leases]) { client in
            let recorder = HostImageRecorder(
                host: host,
                content: ContentAPI.Client(wrapping: client),
                images: ImagesAPI.Client(wrapping: client),
                leases: LeasesAPI.Client(wrapping: client),
                platform: Platform(arch: "arm64", os: "linux")
            )
            try await body(recorder, images, leases)
        }
    }

    @Test func recordCopiesThePlatformBlobsIntoContainerd() async throws {
        let content = FakeContent()
        try await withConnectedRecorder(host: FakeHostStore(blobs: Self.hostBlobs), content: content) { recorder, _, _ in
            try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)
        }

        let stored = content.blobs.withLock { $0.mapValues(\.data) }
        #expect(stored == Self.hostBlobs)
    }

    @Test func recordLabelsBlobsForGarbageCollection() async throws {
        let content = FakeContent()
        try await withConnectedRecorder(host: FakeHostStore(blobs: Self.hostBlobs), content: content) { recorder, _, _ in
            try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)
        }

        let manifestLabels = content.blobs.withLock { $0[Self.manifestDescriptor.digest]?.labels }
        #expect(
            manifestLabels == [
                "containerd.io/gc.ref.content.config": Self.configDescriptor.digest,
                "containerd.io/gc.ref.content.l.0": Self.layerDescriptor.digest,
            ])
    }

    @Test func recordCreatesTheImageAndReleasesTheLease() async throws {
        try await withConnectedRecorder(host: FakeHostStore(blobs: Self.hostBlobs), content: FakeContent()) { recorder, images, leases in
            try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)

            #expect(images.targets.withLock { $0 } == ["docker.io/library/foo:dev": Self.indexDescriptor.digest])
            #expect(leases.created.withLock { $0 } == 1)
            #expect(leases.current.withLock { $0 }.isEmpty)
        }
    }

    @Test func recordDoesNotCopyBlobsContainerdHas() async throws {
        let content = FakeContent(blobs: [Self.layerDescriptor.digest: FakeBlob(data: Self.layer, labels: [:])])
        try await withConnectedRecorder(host: FakeHostStore(blobs: Self.hostBlobs), content: content) { recorder, _, _ in
            try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)
        }

        let written = Set(content.writes.withLock { $0.keys })
        #expect(written == [Self.indexDescriptor.digest, Self.manifestDescriptor.digest, Self.configDescriptor.digest])
    }

    @Test func recordLeasesEveryBlob() async throws {
        let content = FakeContent(blobs: [Self.layerDescriptor.digest: FakeBlob(data: Self.layer, labels: [:])])
        try await withConnectedRecorder(host: FakeHostStore(blobs: Self.hostBlobs), content: content) { recorder, _, leases in
            try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)

            #expect(Array(leases.content.withLock { $0 }.values) == [Set(Self.hostBlobs.keys)])
        }
    }

    @Test func recordStopsAtABlobLargerThanItsDescriptor() async throws {
        var blobs = Self.hostBlobs
        blobs[Self.layerDescriptor.digest] = Self.layer + Data("extra".utf8)
        let host = FakeHostStore(blobs: blobs, reportedSizes: [Self.layerDescriptor.digest: Self.layerDescriptor.size])
        let content = FakeContent()
        try await withConnectedRecorder(host: host, content: content) { recorder, _, leases in
            do {
                try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)
                Issue.record("expected an error")
            } catch let error as RPCError {
                #expect(error.code == .dataLoss)
            }
            #expect(content.blobs.withLock { $0[Self.layerDescriptor.digest] } == nil)
            #expect(leases.current.withLock { $0 }.isEmpty)
        }
    }

    @Test func recordDoesNotNeedTheHostForBlobsContainerdHas() async throws {
        var hostBlobs = Self.hostBlobs
        hostBlobs[Self.layerDescriptor.digest] = nil
        let content = FakeContent(blobs: [Self.layerDescriptor.digest: FakeBlob(data: Self.layer, labels: [:])])
        try await withConnectedRecorder(host: FakeHostStore(blobs: hostBlobs), content: content) { recorder, _, _ in
            try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)
        }

        let stored = content.blobs.withLock { $0.mapValues(\.data) }
        #expect(stored == Self.hostBlobs)
    }

    @Test func recordStreamsOnlyConfigAndLayersFromTheHost() async throws {
        let host = FakeHostStore(blobs: Self.hostBlobs)
        try await withConnectedRecorder(host: host, content: FakeContent()) { recorder, _, _ in
            try await recorder.record(name: "docker.io/library/foo:dev", target: Self.indexDescriptor)
        }

        #expect(host.reads.digests.withLock { $0 } == [Self.configDescriptor.digest, Self.layerDescriptor.digest])
    }

    @Test func largeBlobIsWrittenInChunks() async throws {
        let size = 2 * HostImageRecorder.writeChunkSize + 5
        let layer = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
        let layerDescriptor = Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: digest(of: layer), size: Int64(size))
        let content = FakeContent()
        try await withConnectedRecorder(host: FakeHostStore(blobs: [digest(of: layer): layer]), content: content) { recorder, _, _ in
            try await recorder.record(name: "docker.io/library/foo:dev", target: layerDescriptor)
        }

        let sizes = content.writes.withLock { $0[layerDescriptor.digest] }
        #expect(sizes == [HostImageRecorder.writeChunkSize, HostImageRecorder.writeChunkSize, 5])
        #expect(content.blobs.withLock { $0[layerDescriptor.digest]?.data } == layer)
    }
}
