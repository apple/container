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

import Foundation
import Testing

/// Tests for the `--init-image` flag which allows specifying a custom init filesystem
/// image for microvms. This enables customizing boot-time behavior before the OCI
/// container starts.
///
/// See: https://github.com/apple/container/discussions/838
///
/// Note: A full integration test that verifies custom init behavior would require
/// a pre-built test init image that writes a marker to /dev/kmsg. This can be added
/// once a test init image is published to the registry.
class TestCLIRunInitImage: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    /// Test that specifying a non-existent init-image fails with an appropriate error.
    @Test func testRunWithNonExistentInitImage() throws {
        let name = getTestName()
        let nonExistentImage = "nonexistent.invalid/init-image:does-not-exist"

        #expect(throws: CLIError.self, "expected container run with non-existent init-image to fail") {
            let (_, _, error, status) = try run(arguments: [
                "run",
                "--rm",
                "--name", name,
                "-d",
                "--init-image", nonExistentImage,
                alpine,
                "sleep", "infinity",
            ])
            defer { try? doRemove(name: name, force: true) }
            if status != 0 {
                throw CLIError.executionFailed("command failed: \(error)")
            }
        }
    }

    /// Test that the `--init-image` flag is recognized and documented in CLI help.
    @Test func testInitImageFlagInHelp() throws {
        let (_, output, _, status) = try run(arguments: ["run", "--help"])
        #expect(status == 0, "expected help command to succeed")
        #expect(
            output.contains("--init-image"),
            "expected help output to contain --init-image flag"
        )
        #expect(
            output.contains("custom init image"),
            "expected help output to describe the init-image flag"
        )
    }

    /// Test that the `--init-image` flag works with `container create` command.
    @Test func testCreateWithNonExistentInitImage() throws {
        let name = getTestName()
        let nonExistentImage = "nonexistent.invalid/init-image:does-not-exist"

        #expect(throws: CLIError.self, "expected container create with non-existent init-image to fail") {
            let (_, _, error, status) = try run(arguments: [
                "create",
                "--rm",
                "--name", name,
                "--init-image", nonExistentImage,
                alpine,
                "echo", "hello",
            ])
            defer { try? doRemove(name: name, force: true) }
            if status != 0 {
                throw CLIError.executionFailed("command failed: \(error)")
            }
        }
    }

    /// Test that explicitly specifying the default init image works the same as
    /// not specifying any init image.
    @Test func testRunWithExplicitDefaultInitImage() throws {
        let name = getTestName()

        // Get the default init image reference
        let (_, defaultInitImage, _, propStatus) = try run(arguments: [
            "system", "property", "get", "image.init",
        ])

        guard propStatus == 0 else {
            print("Skipping testRunWithExplicitDefaultInitImage: could not get default init image")
            return
        }

        let initImage = defaultInitImage.trimmingCharacters(in: .whitespacesAndNewlines)

        // Run container with explicit default init image
        try doLongRun(name: name, args: ["--init-image", initImage])
        defer {
            try? doStop(name: name)
        }

        // Verify container is running and functional
        try waitForContainerRunning(name)
        let output = try doExec(name: name, cmd: ["echo", "hello"])
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello",
            "expected 'hello' output from exec, got '\(output)'"
        )
    }
}
