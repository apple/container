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

import Testing

@testable import ContainerResource
@testable import ContainerSandboxService

struct SandboxServiceHostsTest {
    @Test
    func testResolvedHostsIncludesDefaultsPrimaryAddressAndExtraHosts() {
        let extraHosts = [
            ContainerConfiguration.HostEntry(ipAddress: "192.168.64.1", hostnames: ["host.docker.internal"]),
            ContainerConfiguration.HostEntry(ipAddress: "10.0.0.15", hostnames: ["db", "db.internal"]),
        ]

        let hosts = SandboxService.resolvedHosts(
            hostname: "web",
            primaryAddress: "192.168.64.22/24",
            extraHosts: extraHosts
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(ipAddress: "127.0.0.1", hostnames: ["localhost"]),
            ContainerConfiguration.HostEntry(ipAddress: "192.168.64.22", hostnames: ["web"]),
            ContainerConfiguration.HostEntry(ipAddress: "192.168.64.1", hostnames: ["host.docker.internal"]),
            ContainerConfiguration.HostEntry(ipAddress: "10.0.0.15", hostnames: ["db", "db.internal"]),
        ])
    }
}
