//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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
import ContainerizationOCI
import ComposeCore
import Foundation
import Testing

@testable import ComposePlugin

struct TargetsUtilTests {
    @Test
    func testSelectTargetsMatchesProjectLabelsAndContainerPrefix() {
        let project = Project(
            name: "demo",
            services: [
                "web": Service(name: "web"),
                "db": Service(name: "db"),
            ]
        )

        let targets = TargetsUtil.selectTargets(
            project: project,
            services: [],
            containers: [
                makeSnapshot(
                    id: "random-web-id",
                    labels: [
                        "com.apple.compose.project": "demo",
                        "com.apple.compose.service": "web",
                    ]
                ),
                makeSnapshot(id: "demo_db"),
                makeSnapshot(
                    id: "ignored",
                    labels: [
                        "com.apple.compose.project": "other",
                        "com.apple.compose.service": "web",
                    ]
                ),
            ]
        )

        #expect(targets.count == 2)
        #expect(targets.map(\.service) == ["web", "db"])
        #expect(targets.map(\.container.id) == ["random-web-id", "demo_db"])
    }

    @Test
    func testSelectTargetsRespectsServiceFilter() {
        let project = Project(
            name: "demo",
            services: [
                "web": Service(name: "web"),
                "db": Service(name: "db"),
            ]
        )

        let targets = TargetsUtil.selectTargets(
            project: project,
            services: ["db"],
            containers: [
                makeSnapshot(id: "demo_web"),
                makeSnapshot(id: "demo_db"),
            ]
        )

        #expect(targets.count == 1)
        #expect(targets[0].service == "db")
        #expect(targets[0].container.id == "demo_db")
    }

    @Test
    func testComputePrefixWidthUsesLongestContainerIdAndCapsAtMaxWidth() {
        let shortTarget = (service: "web", container: makeSnapshot(id: "demo_web"))
        let longTarget = (service: "db", container: makeSnapshot(id: String(repeating: "x", count: 80)))

        #expect(TargetsUtil.computePrefixWidth(targets: [shortTarget], maxWidth: 40) == 8)
        #expect(TargetsUtil.computePrefixWidth(targets: [shortTarget, longTarget], maxWidth: 40) == 40)
        #expect(TargetsUtil.computePrefixWidth(targets: [], maxWidth: 40) == 0)
    }

    private func makeSnapshot(id: String, labels: [String: String] = [:]) -> ContainerSnapshot {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:\(String(repeating: "0", count: 64))",
            size: 1
        )
        let image = ImageDescription(reference: "test:latest", descriptor: descriptor)
        let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.labels = labels
        return ContainerSnapshot(configuration: configuration, status: .running, networks: [])
    }
}
