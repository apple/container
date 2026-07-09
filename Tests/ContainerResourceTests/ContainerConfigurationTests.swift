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

@testable import ContainerResource

// Shared fixture (reused by later tasks' tests). If an initializer is rejected,
// correct it against Sources/ContainerResource/Image/ImageDescription.swift and
// Sources/ContainerResource/Container/ProcessConfiguration.swift.
func makeTestConfiguration(
    id: String = "test-ctr",
    labels: [String: String] = [:],
    creationDate: Date? = nil
) -> ContainerConfiguration {
    let image = ImageDescription(
        reference: "docker.io/library/alpine:latest",
        descriptor: .init(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:" + String(repeating: "0", count: 64),
            size: 0
        )
    )
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
    var config = ContainerConfiguration(id: id, image: image, process: process)
    config.labels = labels
    if let creationDate { config.creationDate = creationDate }
    return config
}

struct ContainerConfigurationResourcesTests {
    @Test func roundTripsCpuOverhead() throws {
        var config = makeTestConfiguration()
        config.resources.cpuOverhead = 2
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.resources.cpuOverhead == 2)
    }

    @Test func decodesMissingCpuOverheadAsDefault() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var resources = try #require(obj["resources"] as? [String: Any])
        resources.removeValue(forKey: "cpuOverhead")
        obj["resources"] = resources
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.resources.cpuOverhead == 1)
    }
}

struct ContainerConfigurationCreationDateTests {
    @Test func roundTripsCreationDate() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let config = makeTestConfiguration(creationDate: when)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.creationDate == when)
    }

    @Test func decodesMissingCreationDateAsEpoch() throws {
        let config = makeTestConfiguration(creationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "creationDate")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.creationDate == Date(timeIntervalSince1970: 0))
    }
}
