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

/// Pulls each image in ``ContainerFixture/warmupImages`` in parallel before
/// concurrent integration tests run. The Makefile's warmup pass runs this
/// suite first so that ``ContainerFixture/copyWarmupImage(_:)`` can tag
/// from a pre-populated store rather than pulling on demand.
@Suite
struct ImageWarmup {
    @Test(arguments: ContainerFixture.warmupImages)
    func pull(image: String) async throws {
        try await ContainerFixture.with { f in
            try f.run(["image", "pull", image]).check("failed to pull \(image)")
        }
    }
}
