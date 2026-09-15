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
import ContainerizationOCI
import Testing

@testable import ContainerAPIClient

struct ClientImageSearchTests {
    private func image(reference: String, digest: String) -> ClientImage {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: digest,
            size: 100
        )
        return ClientImage(description: ImageDescription(reference: reference, descriptor: descriptor))
    }

    private let digest = "sha256:" + String(repeating: "a", count: 64)
    private let otherDigest = "sha256:" + String(repeating: "b", count: 64)

    private var images: [ClientImage] {
        [
            image(reference: "docker.io/library/other:latest", digest: otherDigest),
            image(reference: "docker.io/library/local-digest-repro:test", digest: digest),
        ]
    }

    @Test func resolvesTaggedDigestToLocalImage() throws {
        // name:tag@digest must resolve the locally stored tagged image by its
        // index descriptor digest instead of falling back to a remote pull.
        let match = try ClientImage.matchByDigest(reference: "local-digest-repro:test@\(digest)", in: images)
        #expect(match?.digest == digest)
    }

    @Test func resolvesNameDigestToLocalImage() throws {
        // The canonical name@digest form resolves the same way.
        let match = try ClientImage.matchByDigest(reference: "local-digest-repro@\(digest)", in: images)
        #expect(match?.digest == digest)
    }

    @Test func referenceWithoutDigestDoesNotMatch() throws {
        let match = try ClientImage.matchByDigest(reference: "local-digest-repro:test", in: images)
        #expect(match == nil)
    }

    @Test func unknownDigestDoesNotMatch() throws {
        let missing = "sha256:" + String(repeating: "c", count: 64)
        let match = try ClientImage.matchByDigest(reference: "local-digest-repro:test@\(missing)", in: images)
        #expect(match == nil)
    }
}
