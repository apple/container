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

struct SystemStatusTests {
    private func makeRunningPayload(
        paths: Application.PathInfo? = nil,
        resources: Application.ResourceCounts? = nil
    ) -> Application.StatusPayload {
        Application.StatusPayload(
            status: "running",
            client: Application.ClientInfo(version: "1.2.3", build: "release", commit: "abcdef", appName: "container"),
            server: Application.ServerInfo(version: "9.9.9", build: "release", commit: "deadbeef", appName: "container-apiserver"),
            host: Application.HostInfo(architecture: "arm64", operatingSystem: "macOS 26.0", cpus: 8),
            paths: paths,
            resources: resources
        )
    }

    @Test
    func tableIncludesStatusClientAndHostWhenRunning() {
        let table = Application.SystemStatus.statusTable(makeRunningPayload())
        #expect(table.contains("FIELD"))
        #expect(table.contains("status"))
        #expect(table.contains("running"))
        #expect(table.contains("client.version"))
        #expect(table.contains("1.2.3"))
        #expect(table.contains("host.architecture"))
        #expect(table.contains("arm64"))
        #expect(table.contains("host.cpus"))
    }

    @Test
    func tableShowsOnlyStatusWhenNotRunning() {
        let table = Application.SystemStatus.statusTable(Application.StatusPayload(status: "not running"))
        #expect(table.contains("status"))
        #expect(table.contains("not running"))
        #expect(!table.contains("client.version"))
        #expect(!table.contains("server.version"))
    }

    @Test
    func tableShowsServerAndDaemonFieldsWhenRunning() {
        let payload = makeRunningPayload(
            paths: Application.PathInfo(appRoot: "/app/root", installRoot: "/install/root", logRoot: "/log/root"),
            resources: {
                var r = Application.ResourceCounts(containersTotal: 5, containersRunning: 2)
                r.images = 7
                return r
            }()
        )
        let table = Application.SystemStatus.statusTable(payload)
        #expect(table.contains("server.version"))
        #expect(table.contains("9.9.9"))
        #expect(table.contains("paths.appRoot"))
        #expect(table.contains("/app/root"))
        #expect(table.contains("containers.total"))
        #expect(table.contains("containers.running"))
        #expect(table.contains("images.total"))
    }

    @Test
    func payloadRoundTripsThroughJSON() throws {
        let payload = makeRunningPayload()
        let json = try Output.renderJSON(payload)
        let decoded = try JSONDecoder().decode(Application.StatusPayload.self, from: Data(json.utf8))
        #expect(decoded.status == "running")
        #expect(decoded.client?.version == "1.2.3")
        #expect(decoded.server?.commit == "deadbeef")
        #expect(decoded.host?.cpus == 8)
        #expect(decoded.paths == nil)
    }

    @Test
    func imageCountIsRecordedOnResourceCounts() {
        let resources = Application.ResourceCounts(containersTotal: 3, containersRunning: 1)
        let updated = Application.SystemStatus.withImageCount(resources, imageCount: 7)
        #expect(updated?.images == 7)
        // And it surfaces in the rendered table.
        let table = Application.SystemStatus.statusTable(makeRunningPayload(resources: updated))
        #expect(table.contains("images.total"))
        #expect(table.contains("7"))
    }

    @Test
    func imageCountWithoutResourceCountsStaysNil() {
        #expect(Application.SystemStatus.withImageCount(nil, imageCount: 7) == nil)
    }

    @Test
    func imageCountOmittedWhenUnavailable() {
        let resources = Application.ResourceCounts(containersTotal: 2, containersRunning: 0)
        let updated = Application.SystemStatus.withImageCount(resources, imageCount: nil)
        #expect(updated?.images == nil)
    }

    // MARK: - JSON round-trip with full payload

    @Test
    func fullPayloadRoundTripsThroughJSON() throws {
        var resources = Application.ResourceCounts(containersTotal: 4, containersRunning: 1)
        resources.images = 3
        let payload = makeRunningPayload(
            paths: Application.PathInfo(appRoot: "/data", installRoot: "/usr/local", logRoot: "/var/log"),
            resources: resources
        )
        let json = try Output.renderJSON(payload)
        let decoded = try JSONDecoder().decode(Application.StatusPayload.self, from: Data(json.utf8))
        #expect(decoded.status == "running")
        #expect(decoded.client?.version == "1.2.3")
        #expect(decoded.client?.build == "release")
        #expect(decoded.client?.commit == "abcdef")
        #expect(decoded.client?.appName == "container")
        #expect(decoded.server?.version == "9.9.9")
        #expect(decoded.server?.build == "release")
        #expect(decoded.server?.commit == "deadbeef")
        #expect(decoded.server?.appName == "container-apiserver")
        #expect(decoded.host?.architecture == "arm64")
        #expect(decoded.host?.operatingSystem == "macOS 26.0")
        #expect(decoded.host?.cpus == 8)
        #expect(decoded.paths?.appRoot == "/data")
        #expect(decoded.paths?.installRoot == "/usr/local")
        #expect(decoded.paths?.logRoot == "/var/log")
        #expect(decoded.resources?.containersTotal == 4)
        #expect(decoded.resources?.containersRunning == 1)
        #expect(decoded.resources?.images == 3)
    }

    // MARK: - PathInfo edge cases

    @Test
    func tableOmitsLogRootRowWhenNil() {
        let payload = makeRunningPayload(
            paths: Application.PathInfo(appRoot: "/data", installRoot: "/usr/local", logRoot: nil)
        )
        let table = Application.SystemStatus.statusTable(payload)
        #expect(table.contains("paths.appRoot"))
        #expect(table.contains("paths.installRoot"))
        #expect(!table.contains("paths.logRoot"))
    }

    @Test
    func tableIncludesLogRootRowWhenPresent() {
        let payload = makeRunningPayload(
            paths: Application.PathInfo(appRoot: "/data", installRoot: "/usr/local", logRoot: "/var/log")
        )
        let table = Application.SystemStatus.statusTable(payload)
        #expect(table.contains("paths.logRoot"))
        #expect(table.contains("/var/log"))
    }

    // MARK: - Unregistered status

    @Test
    func tableShowsOnlyStatusWhenUnregistered() {
        let table = Application.SystemStatus.statusTable(Application.StatusPayload(status: "unregistered"))
        #expect(table.contains("status"))
        #expect(table.contains("unregistered"))
        #expect(!table.contains("client.version"))
        #expect(!table.contains("server.version"))
        #expect(!table.contains("paths.appRoot"))
    }

    // MARK: - Zero image count

    @Test
    func imageCountOfZeroIsRecorded() {
        let resources = Application.ResourceCounts(containersTotal: 2, containersRunning: 0)
        let updated = Application.SystemStatus.withImageCount(resources, imageCount: 0)
        #expect(updated?.images == 0)
        let table = Application.SystemStatus.statusTable(makeRunningPayload(resources: updated))
        #expect(table.contains("images.total"))
        #expect(table.contains("0"))
    }
}
