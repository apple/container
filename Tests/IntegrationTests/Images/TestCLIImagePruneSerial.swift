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

private let alpine = ContainerFixture.warmupImages[0]
private let busybox = ContainerFixture.warmupImages[2]

/// Serial tests for `image prune` and `--max-concurrent-downloads`.
/// These use `image rm --all` which affects global state.
@Suite(.serialized)
struct TestCLIImagePruneSerial {

    @Test func testImageSingleConcurrentDownload() async throws {
        try await ContainerFixture.with { f in
            _ = try? f.run(["image", "rm", alpine])
            f.addCleanup { try? f.doRemoveImages() }
            try f.doPull(alpine, args: ["--max-concurrent-downloads", "1"])
            let present = try f.isImagePresent(alpine)
            #expect(present, "expected image to be pulled with --max-concurrent-downloads 1")
        }
    }

    @Test func testImageManyConcurrentDownloads() async throws {
        try await ContainerFixture.with { f in
            _ = try? f.run(["image", "rm", alpine])
            f.addCleanup { try? f.doRemoveImages() }
            try f.doPull(alpine, args: ["--max-concurrent-downloads", "64"])
            let present = try f.isImagePresent(alpine)
            #expect(present, "expected image to be pulled with --max-concurrent-downloads 64")
        }
    }

    @Test func testImagePruneNoImages() async throws {
        try await ContainerFixture.with { f in
            try? f.doRemoveImages()
            let result = try f.run(["image", "prune"]).check()
            #expect(result.error.contains("Zero KB"), "should show no space reclaimed")
        }
    }

    @Test func testImagePruneUnusedImages() async throws {
        try await ContainerFixture.with { f in
            _ = try? f.run(["delete", "--all", "--force"])
            try? f.doRemoveImages()
            f.addCleanup { try? f.doRemoveImages() }

            try f.doPull(alpine)
            try f.doPull(busybox)
            #expect(try f.isImagePresent(alpine), "expected \(alpine) to be pulled")
            #expect(try f.isImagePresent(busybox), "expected \(busybox) to be pulled")

            let result = try f.run(["image", "prune", "-a"]).check()
            #expect(result.output.contains(alpine), "should prune alpine image")
            #expect(result.output.contains(busybox), "should prune busybox image")

            #expect(try !f.isImagePresent(alpine), "expected \(alpine) to be removed")
            #expect(try !f.isImagePresent(busybox), "expected \(busybox) to be removed")
        }
    }

    @Test func testImagePruneDanglingImages() async throws {
        try await ContainerFixture.with { f in
            let containerName = "\(f.testID)-c"
            _ = try? f.run(["delete", "--all", "--force"])
            try? f.doRemoveImages()
            f.addCleanup {
                try? f.doStop(containerName)
                try? f.doRemove(containerName)
                try? f.doRemoveImages()
            }

            try f.doPull(alpine)
            try f.doPull(busybox)
            #expect(try f.isImagePresent(alpine), "expected \(alpine) to be pulled")
            #expect(try f.isImagePresent(busybox), "expected \(busybox) to be pulled")

            // Keep alpine in use via a running container.
            try f.doLongRun(name: containerName, image: alpine, autoRemove: false)
            try await f.waitForContainerRunning(containerName)

            let result = try f.run(["image", "prune", "-a"]).check()
            #expect(result.output.contains(busybox), "should prune busybox image")
            #expect(try !f.isImagePresent(busybox), "expected \(busybox) to be removed")
            #expect(try f.isImagePresent(alpine), "expected \(alpine) to remain (in use)")
        }
    }
}
