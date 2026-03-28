//===----------------------------------------------------------------------===//
// Copyright © 2026 Mazdak Rezvani and contributors. All rights reserved.
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
import Yams
import Logging

@testable import ComposeCore

struct ExtraHostsTests {
    @Test
    func testDecodeExtraHostsListAndDictForms() throws {
        let yaml = """
        services:
          app:
            image: alpine
            extra_hosts:
              - "host.docker.internal:host-gateway"
              - "db=192.168.64.2"
          worker:
            image: alpine
            extra_hosts:
              host.docker.internal: host-gateway
              db: 192.168.64.2
        """

        let compose = try YAMLDecoder().decode(ComposeFile.self, from: yaml)
        let appHosts = try #require(compose.services["app"]?.extraHosts?.asDictionary)
        #expect(appHosts["host.docker.internal"] == "host-gateway")
        #expect(appHosts["db"] == "192.168.64.2")

        let workerHosts = try #require(compose.services["worker"]?.extraHosts?.asDictionary)
        #expect(workerHosts["host.docker.internal"] == "host-gateway")
        #expect(workerHosts["db"] == "192.168.64.2")
    }

    @Test
    func testProjectConverterCarriesExtraHostsIntoServiceModel() throws {
        let service = ComposeService(
            image: "alpine",
            extraHosts: .list(["host.docker.internal:host-gateway", "db=192.168.64.2"])
        )
        let compose = ComposeFile(services: ["app": service])
        let converter = ProjectConverter(log: Logger(label: "test"), projectDirectory: URL(fileURLWithPath: "/tmp"))

        let project = try converter.convert(composeFile: compose, projectName: "demo")
        let app = try #require(project.services["app"])
        #expect(Set(app.extraHosts.map { "\($0.hostname)=\($0.address)" }) == Set([
            "host.docker.internal=host-gateway",
            "db=192.168.64.2",
        ]))
    }

    @Test
    func testComposeParserPreservesExtraHostsThroughNormalization() throws {
        let tempDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let composeURL = tempDirectory.appendingPathComponent("docker-compose.yaml")
        try """
        services:
          app:
            image: alpine
            extra_hosts:
              - "host.docker.internal:host-gateway"
              - "db=192.168.64.2"
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let parser = ComposeParser(log: Logger(label: "test"), allowAnchors: false)
        let parsed = try parser.parse(from: composeURL)
        let service = try #require(parsed.services["app"])
        let converter = ProjectConverter(log: Logger(label: "test"), projectDirectory: tempDirectory)
        let project = try converter.convert(composeFile: parsed, projectName: "demo")
        let app = try #require(project.services["app"])

        #expect(service.extraHosts?.asDictionary["host.docker.internal"] == "host-gateway")
        #expect(service.extraHosts?.asDictionary["db"] == "192.168.64.2")
        #expect(Set(app.extraHosts.map { "\($0.hostname)=\($0.address)" }) == Set([
            "host.docker.internal=host-gateway",
            "db=192.168.64.2",
        ]))
    }
}
