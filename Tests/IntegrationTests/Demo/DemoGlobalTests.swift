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

/// Demonstration suite for the serial global test pass.
///
/// These two tests are structurally identical to ``DemoConcurrentTests`` but
/// run under ``--experimental-maximum-parallelization-width 1`` in the Makefile
/// to show serial execution. Total wall-clock time should be approximately the
/// sum of the individual durations rather than the maximum.
///
/// Real global tests (image prune, system df, kernel set, etc.) will live here
/// once migrated. Delete this suite at that point.
@Suite
struct DemoGlobalTests {
    @Test func globalTest1() async throws { try await runDemo() }
    @Test func globalTest2() async throws { try await runDemo() }

    private func runDemo() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { _ in
                try await Task.sleep(for: .seconds(Int.random(in: 2...4)))
            }
        }
    }
}
