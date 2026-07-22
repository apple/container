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

/// Tests for the `--init-image` flag which allows specifying a custom init filesystem
/// image for microvms.
///
/// Note: A full integration test that verifies custom init behavior would require
/// a pre-built test init image that writes a marker to /dev/kmsg. This can be added
/// once a test init image is published to the registry.
@Suite
struct TestCLIRunInitImage {
    private let alpine = WarmupImage.alpine320

    @Test func testRunWithNonExistentInitImage() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            f.addCleanup { try? f.doRemove(c, force: true) }
            let result = try f.run([
                "run", "--rm", "--name", c, "-d",
                "--init-image", "nonexistent.invalid/init-image:does-not-exist",
                image, "sleep", "infinity",
            ])
            #expect(result.status != 0, "run with non-existent init-image should fail")
        }
    }

    @Test func testInitImageFlagInHelp() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["run", "--help"]).check()
            #expect(result.output.contains("--init-image"))
            #expect(result.output.contains("custom init image"))
        }
    }

    @Test func testCreateWithNonExistentInitImage() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            f.addCleanup { try? f.doRemove(c, force: true) }
            let result = try f.run([
                "create", "--name", c,
                "--init-image", "nonexistent.invalid/init-image:does-not-exist",
                image, "echo", "hello",
            ])
            #expect(result.status != 0, "create with non-existent init-image should fail")
        }
    }

    @Test func testRunWithExplicitDefaultInitImage() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            let config = try f.getSystemConfig()
            try f.doLongRun(
                name: c, image: image,
                args: ["--init-image", config.vminit.image], autoRemove: false)
            try await f.waitForContainerRunning(c)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let output = try f.doExec(c, cmd: ["echo", "hello"])
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        }
    }
}
