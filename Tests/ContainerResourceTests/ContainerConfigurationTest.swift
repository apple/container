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

import Foundation
import Testing
import ContainerizationOCI

@testable import ContainerResource

struct ContainerConfigurationTest {
    @Test
    func testContainerConfigurationRoundTripsHosts() throws {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                size: 123
            )
        )
        var configuration = ContainerConfiguration(
            id: "web",
            image: image,
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "sleep infinity"],
                environment: []
            )
        )
        configuration.hosts = [
            ContainerConfiguration.HostEntry(ipAddress: "127.0.0.1", hostnames: ["localhost"]),
            ContainerConfiguration.HostEntry(ipAddress: "192.168.64.1", hostnames: ["host.docker.internal"]),
        ]

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: encoded)

        #expect(decoded.hosts == configuration.hosts)
    }
}
