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
import Testing

/// Starts the shared `buildkit` builder, sized for the host, before the
/// concurrent pass runs many builder suites against it at once.
///
/// Without this, `container build`'s auto-start path falls back to
/// `BuildConfig`'s fixed 2 CPU / 2GB product default, which becomes a
/// bottleneck once dozens of concurrent-pool tests submit builds to it
/// simultaneously.
@Suite
struct BuilderWarmup {
    @Test func startBuilder() async throws {
        try await ContainerFixture.with { f in
            try f.builderStart()
            try await f.waitForBuilderRunning()
        }
    }
}
