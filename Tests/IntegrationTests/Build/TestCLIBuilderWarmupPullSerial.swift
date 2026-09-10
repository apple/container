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

/// Serial because this repulls the shared warmup alpine image with `--no-cache`,
/// which would race with concurrent-pool tests relying on it already being cached.
@Suite(.serialized)
struct TestCLIBuilderWarmupPullSerial {
    @Test func testBuildNoCachePullLatestImage() async throws {
        try await ContainerFixture.with { f in
            let dir = try f.createTempDir()
            try f.createContext(
                dir: dir,
                dockerfile: "FROM \(WarmupImage.alpine320.rawValue)\nADD emptyFile /",
                context: [.file("emptyFile", content: .zeroFilled(size: 1))])
            let image = "registry.local/no-cache-pull:\(UUID().uuidString)"
            try f.buildWithPaths(tags: [image], contextDir: dir, otherArgs: ["--pull", "--no-cache"])
            try f.assertImageBuilt(image)
        }
    }
}
