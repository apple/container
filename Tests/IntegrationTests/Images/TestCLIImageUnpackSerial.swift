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

import ContainerPersistence
import ContainerTestSupport
import Foundation
import Testing

/// Serialized: asserts on the shared store's snapshot directories.
@Suite(.serialized)
struct TestCLIImageUnpackSerial {
    private let alpine = WarmupImage.alpine320.rawValue

    private func snapshotExists(digest: String) -> Bool {
        let hex = digest.split(separator: ":").last.map(String.init) ?? digest
        let dir =
            PathUtils.BaseConfigPath.appRoot.basePath()
            .appending("snapshots")
            .appending(hex)
        return FileManager.default.fileExists(atPath: dir.string)
    }

    @Test func testPullUnpacksTheHostPlatformAlone() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine)
            let variants = try f.doInspectImages(alpine).flatMap { $0.variants }
            #expect(variants.count > 1, "the assertion needs a multi-arch reference")

            for variant in variants where variant.platform.os == "linux" {
                let isHost = variant.platform.architecture == "arm64"
                if isHost {
                    #expect(snapshotExists(digest: variant.digest), "the host platform unpacks on pull")
                }
            }
            let foreign = variants.filter { $0.platform.os == "linux" && $0.platform.architecture != "arm64" }
            let foreignUnpacked = foreign.filter { snapshotExists(digest: $0.digest) }
            #expect(
                foreignUnpacked.count < foreign.count || foreign.isEmpty,
                "platforms the host cannot mount stay packed until something asks for them")
        }
    }

    @Test func testExplicitPlatformUnpacksWhatItNames() async throws {
        try await ContainerFixture.with { f in
            try f.doPull(alpine, args: ["--platform", "linux/amd64"])
            let variants = try f.doInspectImages(alpine).flatMap { $0.variants }
            guard let amd64 = variants.first(where: { $0.platform.architecture == "amd64" && $0.platform.os == "linux" }) else {
                throw CommandError.executionFailed("no amd64 variant in \(alpine)")
            }
            #expect(snapshotExists(digest: amd64.digest), "an explicit --platform unpacks exactly what it names")
        }
    }
}
