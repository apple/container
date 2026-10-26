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
import Testing

@testable import ContainerResource

struct ImageResourceTests {
    private static let indexDigest = "sha256:" + String(repeating: "a", count: 64)
    private static let manifestDigest = "sha256:" + String(repeating: "b", count: 64)
    private static let configDigest = "sha256:" + String(repeating: "c", count: 64)

    private static func makeResource() -> ImageResource {
        let descriptor = Descriptor(mediaType: MediaTypes.index, digest: indexDigest, size: 1)
        let configuration = ImageResource.ImageConfiguration(
            description: ImageDescription(reference: "docker.io/library/alpine:3.20", descriptor: descriptor),
            creationDate: Date(timeIntervalSince1970: 0)
        )
        let variant = ImageResource.Variant(
            platform: Platform(arch: "arm64", os: "linux"),
            digest: manifestDigest,
            configDigest: configDigest,
            size: 3,
            config: ContainerizationOCI.Image(architecture: "arm64", os: "linux", rootfs: Rootfs(type: "layers", diffIDs: []))
        )
        return ImageResource(configuration: configuration, variants: [variant])
    }

    @Test func variantEncodesConfigDigest() throws {
        let data = try JSONEncoder().encode(Self.makeResource())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variants = try #require(json["variants"] as? [[String: Any]])

        #expect(variants.count == 1)
        #expect(variants[0]["configDigest"] as? String == Self.configDigest)
        #expect(variants[0]["digest"] as? String == Self.manifestDigest)
    }

    @Test func variantConfigDigestRoundTrips() throws {
        let data = try JSONEncoder().encode(Self.makeResource())
        let decoded = try JSONDecoder().decode(ImageResource.self, from: data)

        #expect(decoded.variants.map(\.configDigest) == [Self.configDigest])
    }
}
