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

/// Demonstration suite for the concurrent test pass.
///
/// These eight tests run under ``--experimental-maximum-parallelization-width``
/// to show bounded parallelism. Each test starts an isolated container (name
/// scoped to its ``ContainerFixture/testID``) and sleeps for a random interval,
/// so the total wall-clock time should be roughly max(individual durations)
/// rather than their sum.
///
/// Delete this suite once real tests have been migrated to ``IntegrationTests``.
@Suite
struct DemoConcurrentTests {
    @Test func test1() async throws { try await runDemo() }
    @Test func test2() async throws { try await runDemo() }
    @Test func test3() async throws { try await runDemo() }
    @Test func test4() async throws { try await runDemo() }
    @Test func test5() async throws { try await runDemo() }
    @Test func test6() async throws { try await runDemo() }
    @Test func test7() async throws { try await runDemo() }
    @Test func test8() async throws { try await runDemo() }

    private func runDemo() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { _ in
                try await Task.sleep(for: .seconds(Int.random(in: 2...4)))
            }
        }
    }
}
