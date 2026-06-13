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

@testable import ContainerCommands

struct SystemInfoTests {
    private func makePayload(
        server: Application.ServerInfo? = nil,
        paths: Application.PathInfo? = nil,
        resources: Application.ResourceCounts? = nil,
        defaults: Application.DefaultsInfo? = nil
    ) -> Application.InfoPayload {
        Application.InfoPayload(
            client: Application.ClientInfo(version: "1.2.3", build: "release", commit: "abcdef", appName: "container"),
            server: server,
            host: Application.HostInfo(architecture: "arm64", operatingSystem: "macOS 26.0", cpus: 8),
            paths: paths,
            resources: resources,
            defaults: defaults
        )
    }

    @Test
    func tableAlwaysIncludesClientAndHost() {
        let table = Application.SystemInfo.infoTable(makePayload())
        #expect(table.contains("FIELD"))
        #expect(table.contains("client.version"))
        #expect(table.contains("1.2.3"))
        #expect(table.contains("host.architecture"))
        #expect(table.contains("arm64"))
        #expect(table.contains("host.cpus"))
    }

    @Test
    func tableShowsServerNotRunningWhenAbsent() {
        let table = Application.SystemInfo.infoTable(makePayload())
        #expect(table.contains("server.status"))
        #expect(table.contains("not running"))
        #expect(!table.contains("server.version"))
    }

    @Test
    func tableShowsServerAndDaemonFieldsWhenRunning() {
        let payload = makePayload(
            server: Application.ServerInfo(version: "9.9.9", build: "release", commit: "deadbeef", appName: "container-apiserver"),
            paths: Application.PathInfo(appRoot: "/app/root", installRoot: "/install/root", logRoot: "/log/root"),
            resources: {
                var r = Application.ResourceCounts(containersTotal: 5, containersRunning: 2)
                r.images = 7
                return r
            }(),
            defaults: Application.DefaultsInfo(
                registryDomain: "docker.io",
                kernelBinaryPath: "opt/kata/vmlinux",
                containerCPUs: 4,
                containerMemory: "1024MB",
                builderImage: "ghcr.io/apple/builder:latest",
                initImage: "vminit:latest",
                dnsDomain: "test.local"
            )
        )
        let table = Application.SystemInfo.infoTable(payload)
        #expect(table.contains("running"))
        #expect(table.contains("server.version"))
        #expect(table.contains("9.9.9"))
        #expect(table.contains("paths.appRoot"))
        #expect(table.contains("/app/root"))
        #expect(table.contains("containers.total"))
        #expect(table.contains("containers.running"))
        #expect(table.contains("images.total"))
        #expect(table.contains("defaults.registryDomain"))
        #expect(table.contains("docker.io"))
        #expect(table.contains("defaults.dnsDomain"))
        #expect(table.contains("test.local"))
    }

    @Test
    func payloadRoundTripsThroughJSON() throws {
        let payload = makePayload(
            server: Application.ServerInfo(version: "9.9.9", build: "release", commit: "deadbeef", appName: "container-apiserver")
        )
        let json = try Output.renderJSON(payload)
        let decoded = try JSONDecoder().decode(Application.InfoPayload.self, from: Data(json.utf8))
        #expect(decoded.client.version == "1.2.3")
        #expect(decoded.server?.commit == "deadbeef")
        #expect(decoded.host.cpus == 8)
        #expect(decoded.paths == nil)
    }

    @Test
    func optionalDNSDomainOmittedWhenNil() {
        let payload = makePayload(
            defaults: Application.DefaultsInfo(
                registryDomain: "docker.io",
                kernelBinaryPath: "opt/kata/vmlinux",
                containerCPUs: 4,
                containerMemory: "1024MB",
                builderImage: "img",
                initImage: "vminit",
                dnsDomain: nil
            )
        )
        let table = Application.SystemInfo.infoTable(payload)
        #expect(table.contains("defaults.registryDomain"))
        #expect(!table.contains("defaults.dnsDomain"))
    }
}
