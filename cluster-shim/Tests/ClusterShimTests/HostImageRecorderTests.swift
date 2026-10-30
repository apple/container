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

    func makeRecorder() -> HostImageRecorder {
        let host = FakeHostStore(blobs: [
            digest(of: Self.index): Self.index,
            digest(of: Self.manifest): Self.manifest,
            digest(of: Self.config): Self.config,
            digest(of: Self.layer): Self.layer,
        ])
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
                BlobCommit(descriptor: Self.configDescriptor, labels: [:]),
                BlobCommit(descriptor: Self.layerDescriptor, labels: [:]),
                BlobCommit(
                    descriptor: Self.manifestDescriptor,
                    labels: [
                        "containerd.io/gc.ref.content.config": Self.configDescriptor.digest,
                        "containerd.io/gc.ref.content.l.0": Self.layerDescriptor.digest,
                    ]),
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

    @Test func commitRequestSendsNoDataAtFullOffset() {
        let request = HostImageRecorder.commitRequest(BlobCommit(descriptor: Self.layerDescriptor, labels: ["k": "v"]))

        #expect(request.action == .commit)
        #expect(request.offset == Self.layerDescriptor.size)
        #expect(request.total == Self.layerDescriptor.size)
        #expect(request.expected == Self.layerDescriptor.digest)
        #expect(request.data.isEmpty)
        #expect(request.labels == ["k": "v"])
    }
}
