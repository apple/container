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
import Testing

@testable import ContainerAPIClient

struct ClientImagePlatformTests {
    private let amd64 = Platform(arch: "amd64", os: "linux")
    private let arm64 = Platform(arch: "arm64", os: "linux")

    private func descriptor(_ platform: Platform?, digest: String, annotations: [String: String]? = nil) -> Descriptor {
        Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: digest, size: 1, annotations: annotations, platform: platform)
    }

    @Test
    func availablePlatformsSkipsAttestationsMissingPlatformsAndDuplicates() {
        let index = Index(manifests: [
            descriptor(amd64, digest: "sha256:a"),
            descriptor(Platform(arch: "unknown", os: "unknown"), digest: "sha256:b", annotations: ["vnd.docker.reference.type": "attestation-manifest"]),
            descriptor(nil, digest: "sha256:c"),
            descriptor(amd64, digest: "sha256:d"),
        ])
        #expect(ClientImage.availablePlatforms(in: index) == [amd64])
    }

    @Test
    func unsupportedPlatformMessageListsAvailablePlatforms() {
        let message = ClientImage.unsupportedPlatformMessage(reference: "docker.io/mailhog/mailhog:v1.0.1", requested: arm64, available: [amd64])
        #expect(message == "image docker.io/mailhog/mailhog:v1.0.1 has no linux/arm64 variant (available: linux/amd64)")
    }

    @Test
    func unsupportedPlatformMessageWithoutPlatforms() {
        let message = ClientImage.unsupportedPlatformMessage(reference: "example/empty:latest", requested: arm64, available: [])
        #expect(message == "image example/empty:latest has no linux/arm64 variant (available: none)")
    }

    @Test
    func platformHintSuggestsRosettaWhenAmd64IsAvailable() {
        #expect(Utility.platformHint(requested: arm64, available: [amd64]) == "Use --arch amd64 or --platform linux/amd64 to run it with Rosetta.")
    }

    @Test
    func platformHintSuggestsFirstAvailableVariantOtherwise() {
        #expect(Utility.platformHint(requested: amd64, available: [arm64]) == "Use --platform linux/arm64 to select one of the available variants.")
        #expect(Utility.platformHint(requested: arm64, available: []) == nil)
    }
}
