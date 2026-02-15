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

/// Unit tests for SSH agent forwarding configuration (`ssh`, `sshAuthSocketPath`).
/// Ensures the config model correctly persists and restores the caller's socket path
/// so runtime resolution (config → runtime env → launchctl) is not regressed.
struct SSHConfigTests {

    @Test("SSH config round-trip: ssh and sshAuthSocketPath are preserved after encode/decode")
    func sshConfigRoundTripPreservesSocketPath() throws {
        var config = makeMinimalConfig()
        config.ssh = true
        config.sshAuthSocketPath = "/path/to/agent.sock"

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: encoded)

        #expect(decoded.ssh == true)
        #expect(decoded.sshAuthSocketPath == "/path/to/agent.sock")
    }

    @Test("SSH config round-trip: ssh false and nil path are preserved")
    func sshConfigRoundTripPreservesFalseAndNil() throws {
        let config = makeMinimalConfig()
        #expect(config.ssh == false)
        #expect(config.sshAuthSocketPath == nil)

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: encoded)

        #expect(decoded.ssh == false)
        #expect(decoded.sshAuthSocketPath == nil)
    }

    @Test("SSH config decode: missing ssh and sshAuthSocketPath default to false and nil")
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
        #expect(decoded.sshAuthSocketPath == nil)
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
