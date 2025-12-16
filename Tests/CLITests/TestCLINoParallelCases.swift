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
@Suite(.serialized)
class TestCLINoParallelCases: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

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

    @Test func testImagePruneNoImages() throws {
        // Prune with no images should succeed
        let (_, output, error, status) = try run(arguments: ["image", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("image prune failed: \(error)")
        }

        #expect(output.contains("Zero KB"), "should show no space reclaimed")
    }

    @Test func testImagePruneUnusedImages() throws {
        // 1. Pull the images
        try doPull(imageName: alpine)
        try doPull(imageName: busybox)

        // 2. Verify the images are present
        let alpinePresent = try isImagePresent(targetImage: alpine)
        #expect(alpinePresent, "expected to see image \(alpine) pulled")
        let busyBoxPresent = try isImagePresent(targetImage: busybox)
        #expect(busyBoxPresent, "expected to see image \(busybox) pulled")

        // 3. Prune with the -a flag should remove all unused images
        let (_, output, error, status) = try run(arguments: ["image", "prune", "-a"])
        if status != 0 {
            throw CLIError.executionFailed("image prune failed: \(error)")
        }
        #expect(output.contains(alpine), "should prune alpine image")
        #expect(output.contains(busybox), "should prune busybox image")

        // 4. Verify the images are gone
        let alpineRemoved = try !isImagePresent(targetImage: alpine)
        #expect(alpineRemoved, "expected image \(alpine) to be removed")
        let busyboxRemoved = try !isImagePresent(targetImage: busybox)
        #expect(busyboxRemoved, "expected image \(busybox) to be removed")
    }

    @Test func testImagePruneDanglingImages() throws {
        let name = getTestName()
        let containerName = "\(name)_container"

        // 1. Pull the images
        try doPull(imageName: alpine)
        try doPull(imageName: busybox)

        // 2. Verify the images are present
        let alpinePresent = try isImagePresent(targetImage: alpine)
        #expect(alpinePresent, "expected to see image \(alpine) pulled")
        let busyBoxPresent = try isImagePresent(targetImage: busybox)
        #expect(busyBoxPresent, "expected to see image \(busybox) pulled")

        // 3. Create a running container based on alpine
        try doLongRun(
            name: containerName,
            image: alpine
        )
        try waitForContainerRunning(containerName)

        // 4. Prune should only remove the dangling image
        let (_, output, error, status) = try run(arguments: ["image", "prune", "-a"])
        if status != 0 {
            throw CLIError.executionFailed("image prune failed: \(error)")
        }
        #expect(output.contains(busybox), "should prune busybox image")

        // 5. Verify the busybox image is gone
        let busyboxRemoved = try !isImagePresent(targetImage: busybox)
        #expect(busyboxRemoved, "expected image \(busybox) to be removed")

        // 6. Verify the alpine image still exists
        let alpineStillPresent = try isImagePresent(targetImage: alpine)
        #expect(alpineStillPresent, "expected image \(alpine) to remain")
    }
}
