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

import ContainerTestSupport
import Foundation
import Testing

/// Tests for `container builder prune`.
///
/// Serialized because pruning acts on the shared `buildkit` container, which
/// would race with in-flight builds in the concurrent pool.
@Suite(.serialized)
struct TestCLIBuilderPruneSerial {
    @Test func testBuilderPruneReturnsSpaceAndKeepsBuilderUsable() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { try? f.builderDelete(force: true) }

            try f.builderStart()
            try await f.waitForBuilderRunning()

            // Seed the cache so the prune has something to walk.
            let dir = try f.createTempDir()
            try f.createContext(
                dir: dir,
                dockerfile: """
                    FROM scratch
                    ENV SEED=cache
                    """)
            try f.build(tag: "test-prune-seed:\(f.testID)", contextDir: dir)

            let result = try f.run(["builder", "prune", "--all"]).check()
            #expect(result.output.contains("returned"), "prune reports the space it returned")

            // The builder serves builds after a prune: the cache was cost,
            // not correctness.
            let dir2 = try f.createTempDir()
            try f.createContext(
                dir: dir2,
                dockerfile: """
                    FROM scratch
                    ENV SEED=after-prune
                    """)
            try f.build(tag: "test-prune-after:\(f.testID)", contextDir: dir2)
        }
    }

    @Test func testBuilderPruneKeepStorageParses() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { try? f.builderDelete(force: true) }

            try f.builderStart()
            try await f.waitForBuilderRunning()

            let result = try f.run(["builder", "prune", "--keep-storage", "1G"]).check()
            #expect(result.output.contains("returned"), "prune reports the space it returned")
        }
    }
}
