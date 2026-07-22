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
import ContainerizationOCI
import Testing

@testable import ContainerAPIClient

struct ClientImageLookupTests {
    private let containerSystemConfig = ContainerSystemConfig()

    @Test
    func testMatchUsesDisplayedDefaultRegistryNameWhenUnique() throws {
        let ubuntu = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "01a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let fedora = Self.image(
            reference: "docker.io/library/fedora:latest",
            digest: "11a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "ubuntu", in: [fedora, ubuntu], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == ubuntu.reference)
    }

    @Test
    func testMatchDoesNotGuessAmbiguousDisplayedNames() throws {
        let jammy = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "21a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let noble = Self.image(
            reference: "docker.io/library/ubuntu:24.04",
            digest: "31a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "ubuntu", in: [jammy, noble], containerSystemConfig: containerSystemConfig)

        #expect(match == nil)
    }

    @Test
    func testMatchUsesDigestPrefixFromImageList() throws {
        let ubuntu = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "e10577f0db681cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "e10577f0db68", in: [ubuntu], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == ubuntu.reference)
    }

    @Test
    func testMatchDoesNotTreatHexTagsAsDigestPrefixes() throws {
        let digestMatch = Self.image(
            reference: "docker.io/library/fedora:latest",
            digest: "deadbeefdead1cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let tagged = Self.image(
            reference: "docker.io/library/foo:deadbeefdead",
            digest: "71a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "foo:deadbeefdead", in: [digestMatch, tagged], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == tagged.reference)
    }

    @Test
    func testMatchDoesNotGuessAmbiguousDigestPrefixes() throws {
        let first = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "d56a2534ffd21cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let second = Self.image(
            reference: "docker.io/library/fedora:latest",
            digest: "d56a2534ffd22cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "d56a2534ffd2", in: [first, second], containerSystemConfig: containerSystemConfig)

        #expect(match == nil)
    }

    @Test
    func testMatchKeepsNormalizedReferenceBehavior() throws {
        let ubuntu = Self.image(
            reference: "docker.io/library/ubuntu:latest",
            digest: "41a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "ubuntu", in: [ubuntu], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == ubuntu.reference)
    }

    @Test
    func testMatchPreservesLocalImageAnnotationPreference() throws {
        let remote = Self.image(
            reference: "docker.io/library/foo:latest",
            digest: "51a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let local = Self.image(
            reference: "registry.local/builds/foo:latest",
            digest: "61a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000",
            annotations: [AnnotationKeys.containerizationImageName: "foo:latest"]
        )

        let match = try ClientImage.match(reference: "foo", in: [remote, local], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == local.reference)
    }

    private static func image(reference: String, digest: String, annotations: [String: String]? = nil) -> ClientImage {
        let descriptor = Descriptor(mediaType: MediaTypes.index, digest: "sha256:\(digest)", size: 0, annotations: annotations)
        let description = ImageDescription(reference: reference, descriptor: descriptor)
        return ClientImage(description: description)
    }
}
