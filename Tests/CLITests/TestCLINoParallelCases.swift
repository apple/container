//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerClient
import ContainerizationOCI
import Foundation
import Testing

/// Tests that need total control over environment to avoid conflicts.
class TestCLINoParallelCases: CLITest {
    @Test func testImageSingleConcurrentDownload() throws {
        // removing this image during parallel tests breaks stuff!
        _ = try? run(arguments: ["image", "rm", alpine])
        do {
            try doPull(imageName: alpine, args: ["--max-concurrent-downloads", "1"])
            let imagePresent = try isImagePresent(targetImage: alpine)
            #expect(imagePresent, "Expected image to be pulled with maxConcurrentDownloads=1")
        } catch {
            Issue.record("failed to pull image with maxConcurrentDownloads flag: \(error)")
            return
        }
    }

    @Test func testImageManyConcurrentDownloads() throws {
        // removing this image during parallel tests breaks stuff!
        _ = try? run(arguments: ["image", "rm", alpine])
        do {
            try doPull(imageName: alpine, args: ["--max-concurrent-downloads", "64"])
            let imagePresent = try isImagePresent(targetImage: alpine)
            #expect(imagePresent, "Expected image to be pulled with maxConcurrentDownloads=64")
        } catch {
            Issue.record("failed to pull image with maxConcurrentDownloads flag: \(error)")
            return
        }
    }
}
