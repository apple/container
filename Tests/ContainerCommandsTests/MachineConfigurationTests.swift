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
import Containerization
import ContainerizationOCI
import Foundation
import MachineAPIClient
import Testing

struct MachineConfigurationTests {
    private func makeConfig(
        maskedPaths: [String]? = nil,
        readonlyPaths: [String]? = nil
    ) throws -> MachineConfiguration {
        try MachineConfiguration(
            id: "test-machine",
            image: ImageDescription(
                reference: "ghcr.io/linuxcontainers/alpine:3.20",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    size: 64
                )
            ),
            platform: Platform(arch: "arm64", os: "linux"),
            userSetup: UserSetup(username: "tester", uid: 501, gid: 20),
            maskedPaths: maskedPaths,
            readonlyPaths: readonlyPaths
        )
    }

    @Test func testCodableRoundTripWithoutPaths() throws {
        let original = try makeConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MachineConfiguration.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.maskedPaths == nil)
        #expect(decoded.readonlyPaths == nil)
    }

    @Test func testCodableRoundTripWithPaths() throws {
        let original = try makeConfig(
            maskedPaths: ["/run/secrets", "/proc/kcore"],
            readonlyPaths: ["/etc/config"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MachineConfiguration.self, from: data)

        #expect(decoded.maskedPaths == ["/run/secrets", "/proc/kcore"])
        #expect(decoded.readonlyPaths == ["/etc/config"])
    }

    @Test func testDecodeDownRevisionWithoutKeys() throws {
        // A config.json written by an older version of `container` has no
        // maskedPaths/readonlyPaths keys; decoding must not fail.
        let json = """
            {
                "id": "test-machine",
                "image": {
                    "reference": "ghcr.io/linuxcontainers/alpine:3.20",
                    "descriptor": {
                        "mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                        "size": 64
                    }
                },
                "platform": { "architecture": "arm64", "os": "linux" },
                "userSetup": { "username": "tester", "uid": 501, "gid": 20 }
            }
            """
        let decoded = try JSONDecoder().decode(
            MachineConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(decoded.id == "test-machine")
        #expect(decoded.maskedPaths == nil)
        #expect(decoded.readonlyPaths == nil)
    }
}
