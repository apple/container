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

import ContainerResource
import Foundation
import Testing

@testable import ContainerCluster

struct ClusterSupportedVersionsTests {
    @Test
    func defaultIsTheNewestSupportedVersion() {
        #expect(ClusterHelper.nodeImage == ClusterHelper.supportedVersions[0].nodeImage)
    }

    @Test
    func eachImageIsPinnedAndMatchesItsVersion() throws {
        var seen = Set<String>()
        for entry in ClusterHelper.supportedVersions {
            #expect(seen.insert(entry.kubernetesVersion).inserted, "duplicate \(entry.kubernetesVersion)")
            #expect(entry.nodeImage.contains("@sha256:"), "\(entry.nodeImage) isn't pinned by digest")
            let tag = try ClusterConfiguration.kubernetesVersion(nodeImage: entry.nodeImage)
            #expect(tag.hasPrefix("v\(entry.kubernetesVersion)."), "\(entry.nodeImage) isn't a \(entry.kubernetesVersion) image")
        }
    }

    @Test
    func versionsAreNewestFirst() {
        let minors = ClusterHelper.supportedVersions.map { Int($0.kubernetesVersion.split(separator: ".")[1]) ?? 0 }
        #expect(minors == minors.sorted(by: >))
    }

    @Test
    func docsListTheSameVersionsAndImages() throws {
        let docs = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/cluster.md")
        let text = try String(contentsOf: docs, encoding: .utf8)
        for (index, entry) in ClusterHelper.supportedVersions.enumerated() {
            let label = index == 0 ? "\(entry.kubernetesVersion) (default)" : entry.kubernetesVersion
            #expect(text.contains("| \(label) | `\(entry.nodeImage)` |"), "docs/cluster.md is missing \(entry.kubernetesVersion)")
        }
    }
}
