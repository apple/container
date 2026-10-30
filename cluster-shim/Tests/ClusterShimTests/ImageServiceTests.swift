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
import Logging
import Synchronization
import Testing

@testable import ClusterShim

/// containerd's CRI image service, holding image IDs by normalized reference.
final class FakeCRI: CRIImageAPI.SimpleServiceProtocol {
    let images: Mutex<[String: String]>
    let pulls = Mutex<[String]>([])
    /// Status calls that still report no image, standing in for the CRI
    /// plugin handling an image's create event late.
    let staleStatusCalls = Mutex(0)

    init(images: [String: String]) {
        self.images = Mutex(images)
    }

    func imageStatus(request: Runtime_V1_ImageStatusRequest, context: ServerContext) async throws -> Runtime_V1_ImageStatusResponse {
        var response = Runtime_V1_ImageStatusResponse()
        let stale = staleStatusCalls.withLock { calls in
            guard calls > 0 else {
                return false
            }
            calls -= 1
            return true
        }
        if stale {
            return response
        }
        let id = images.withLock { $0[normalizedReference(request.image.image) ?? ""] }
        if let id {
            response.image.id = id
        }
        return response
    }

    func pullImage(request: Runtime_V1_PullImageRequest, context: ServerContext) async throws -> Runtime_V1_PullImageResponse {
        pulls.withLock { $0.append(request.image.image) }
        var response = Runtime_V1_PullImageResponse()
        response.imageRef = "sha256:upstream"
        return response
    }

    func listImages(request: Runtime_V1_ListImagesRequest, context: ServerContext) async throws -> Runtime_V1_ListImagesResponse {
        Runtime_V1_ListImagesResponse()
    }

    func removeImage(request: Runtime_V1_RemoveImageRequest, context: ServerContext) async throws -> Runtime_V1_RemoveImageResponse {
        Runtime_V1_RemoveImageResponse()
    }

    func streamImages(
        request: Runtime_V1_StreamImagesRequest,
        response: RPCWriter<Runtime_V1_StreamImagesResponse>,
        context: ServerContext
    ) async throws {}

    func imageFsInfo(request: Runtime_V1_ImageFsInfoRequest, context: ServerContext) async throws -> Runtime_V1_ImageFsInfoResponse {
        Runtime_V1_ImageFsInfoResponse()
    }
}

struct ImageServiceTests {
    static let hostImages = [
        "docker.io/library/foo:dev": Descriptor(mediaType: MediaTypes.index, digest: digest(of: Data("index".utf8)), size: 5)
    ]

    /// Runs `body` with a CRI client for an image service in front of `cri`.
    /// Recording a host image adds it to `cri` with ID sha256:host and
    /// appends its reference to the returned list.
    func withImageClient(
        cri: FakeCRI,
        host: FakeHostStore = FakeHostStore(images: hostImages),
        _ body: (CRIImageAPI.Client<InProcessTransport.Client>) async throws -> Void
    ) async throws -> [String] {
        let recorded = Mutex<[String]>([])
        try await withInProcessServer(services: [cri]) { containerd in
            let service = ImageService(
                containerd: CRIImageAPI.Client(wrapping: containerd),
                host: host,
                recordHostImage: { reference in
                    recorded.withLock { $0.append(reference) }
                    cri.images.withLock { $0[reference] = "sha256:host" }
                },
                log: Logger(label: "test")
            )
            try await withInProcessServer(services: [service]) { client in
                try await body(CRIImageAPI.Client(wrapping: client))
            }
        }
        return recorded.withLock { $0 }
    }

    func spec(_ image: String) -> Runtime_V1_ImageSpec {
        var spec = Runtime_V1_ImageSpec()
        spec.image = image
        return spec
    }

    @Test func pullRecordsHostImage() async throws {
        let cri = FakeCRI(images: [:])
        var reference = ""
        let recorded = try await withImageClient(cri: cri) { client in
            var request = Runtime_V1_PullImageRequest()
            request.image = spec("foo:dev")
            reference = try await client.pullImage(request).imageRef
        }

        #expect(reference == "sha256:host")
        #expect(recorded == ["docker.io/library/foo:dev"])
        #expect(cri.pulls.withLock { $0 }.isEmpty)
    }

    @Test func pullWaitsForContainerdToSeeRecordedImage() async throws {
        let cri = FakeCRI(images: [:])
        var reference = ""
        _ = try await withImageClient(cri: cri) { client in
            cri.staleStatusCalls.withLock { $0 = 3 }
            var request = Runtime_V1_PullImageRequest()
            request.image = spec("foo:dev")
            reference = try await client.pullImage(request).imageRef
        }

        #expect(reference == "sha256:host")
    }

    @Test func pullForwardsWhenHostLacksImage() async throws {
        let cri = FakeCRI(images: [:])
        var reference = ""
        let recorded = try await withImageClient(cri: cri) { client in
            var request = Runtime_V1_PullImageRequest()
            request.image = spec("bar:dev")
            reference = try await client.pullImage(request).imageRef
        }

        #expect(reference == "sha256:upstream")
        #expect(recorded.isEmpty)
        #expect(cri.pulls.withLock { $0 } == ["bar:dev"])
    }

    @Test func pullForwardsWhenHostIsUnavailable() async throws {
        let cri = FakeCRI(images: [:])
        let host = FakeHostStore(images: Self.hostImages, unavailable: true)
        _ = try await withImageClient(cri: cri, host: host) { client in
            var request = Runtime_V1_PullImageRequest()
            request.image = spec("foo:dev")
            _ = try await client.pullImage(request)
        }

        #expect(cri.pulls.withLock { $0 } == ["foo:dev"])
    }

    @Test func statusRecordsMissingHostImage() async throws {
        let cri = FakeCRI(images: [:])
        var id = ""
        _ = try await withImageClient(cri: cri) { client in
            var request = Runtime_V1_ImageStatusRequest()
            request.image = spec("foo:dev")
            id = try await client.imageStatus(request).image.id
        }

        #expect(id == "sha256:host")
    }

    @Test func statusUsesContainerdImageFirst() async throws {
        let cri = FakeCRI(images: ["docker.io/library/foo:dev": "sha256:local"])
        var id = ""
        let recorded = try await withImageClient(cri: cri) { client in
            var request = Runtime_V1_ImageStatusRequest()
            request.image = spec("foo:dev")
            id = try await client.imageStatus(request).image.id
        }

        #expect(id == "sha256:local")
        #expect(recorded.isEmpty)
    }

    @Test func statusMissingEverywhereHasNoImage() async throws {
        let cri = FakeCRI(images: [:])
        var hasImage = true
        _ = try await withImageClient(cri: cri) { client in
            var request = Runtime_V1_ImageStatusRequest()
            request.image = spec("bar:dev")
            hasImage = try await client.imageStatus(request).hasImage
        }

        #expect(!hasImage)
    }
}

struct NormalizedReferenceTests {
    @Test func shortNameGetsDockerHubLibraryAndLatest() {
        #expect(normalizedReference("foo") == "docker.io/library/foo:latest")
    }

    @Test func tagIsKept() {
        #expect(normalizedReference("foo:dev") == "docker.io/library/foo:dev")
    }

    @Test func otherRegistryKeepsPath() {
        #expect(normalizedReference("ghcr.io/apple/foo:1") == "ghcr.io/apple/foo:1")
    }

    @Test func invalidReferenceIsNil() {
        #expect(normalizedReference("UPPER:case") == nil)
    }
}
