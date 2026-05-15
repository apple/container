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

struct ContainerConfigurationExtraHostsTests {

    private func makeConfig() -> ContainerConfiguration {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: []
        )
        return ContainerConfiguration(id: "abc123", image: image, process: process)
    }

    /// A configuration encoded by an older daemon will not contain the
    /// `extraHosts` key at all. Decoding such payload must succeed and
    /// default `extraHosts` to `[]`.
    @Test("Legacy configuration JSON decodes with empty extraHosts")
    func legacyConfigDecodes() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = makeConfig()
        let data = try encoder.encode(original)

        guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("encoded configuration was not a JSON object")
            return
        }
        dict.removeValue(forKey: "extraHosts")
        let strippedData = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try decoder.decode(ContainerConfiguration.self, from: strippedData)
        #expect(decoded.extraHosts == [])
    }

    @Test("Populated extraHosts round-trip through JSON")
    func extraHostsRoundTrip() throws {
        var config = makeConfig()
        config.extraHosts = [
            .init(hostname: "db", ipAddress: "192.168.66.2"),
            .init(hostname: "cache", ipAddress: "fe80::1"),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(ContainerConfiguration.self, from: data)

        #expect(decoded.extraHosts == config.extraHosts)
    }

    @Test("Default configuration has empty extraHosts")
    func defaultExtraHostsIsEmpty() {
        let config = makeConfig()
        #expect(config.extraHosts == [])
    }
}
