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

/// Unit tests for SSH agent forwarding configuration (`ssh`).
/// The SSH agent socket path is supplied at bootstrap time by the client, not stored in config.
struct SSHConfigTests {

    @Test("SSH config round-trip: ssh true is preserved after encode/decode")
    func sshConfigRoundTripPreservesTrue() throws {
        var config = makeMinimalConfig()
        config.ssh = true

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: encoded)

        #expect(decoded.ssh == true)
    }

    @Test("SSH config round-trip: ssh false is preserved")
    func sshConfigRoundTripPreservesFalse() throws {
        let config = makeMinimalConfig()
        #expect(config.ssh == false)

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: encoded)

        #expect(decoded.ssh == false)
    }

    @Test("SSH config decode: missing ssh defaults to false")
    func sshConfigDecodeDefaults() throws {
        let minimalJSON = """
            {
                "id": "test",
                "image": {"reference": "alpine", "descriptor": {"digest": "sha256:test", "mediaType": "application/vnd.oci.image.manifest.v1+json", "size": 0}},
                "initProcess": {
                    "executable": "/bin/sh",
                    "arguments": [],
                    "environment": [],
                    "workingDirectory": "/",
                    "terminal": false,
                    "user": {"id": {"uid": 0, "gid": 0}},
                    "supplementalGroups": [],
                    "rlimits": []
                }
            }
            """
        let data = minimalJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.ssh == false)
    }

    private func makeMinimalConfig() -> ContainerConfiguration {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:test",
            size: 0
        )
        let image = ImageDescription(reference: "alpine", descriptor: descriptor)
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        return ContainerConfiguration(id: "test", image: image, process: process)
    }
}
