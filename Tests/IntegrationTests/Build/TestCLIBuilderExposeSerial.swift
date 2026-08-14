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

/// Tests for the builder's buildkit exposure knobs: environment
/// inheritance, daemon flag passthrough, and socket publishing.
///
/// Serialized because starting and deleting the shared `buildkit`
/// container would race with in-flight builds in the concurrent pool.
@Suite(.serialized)
struct TestCLIBuilderExposeSerial {

    /// One builder start carries all three knobs; each lands where its
    /// consumer reads it.
    @Test func testBuilderStartCarriesEnvFlagsAndPublishedSocket() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { try? f.builderDelete(force: true) }

            let marker = "echo-\(f.testID)"
            let sockDir = try f.makeShortSocketDir("bk")
            let hostSocket = "\(sockDir)/buildkitd.sock"

            try f.run(
                [
                    "builder", "start",
                    // The value begins with a dash, so it attaches to the
                    // option rather than following it as a separate word.
                    "--buildkitd-flags=--debug",
                    "--publish-buildkit-socket", hostSocket,
                ],
                env: ["BUILDKIT_TEST_MARKER": marker]
            ).check()
            try await f.waitForBuilderRunning()

            // Every BUILDKIT_* variable in the CLI's environment rides into
            // the builder's init process, where the shim reads it.
            let environ = try f.doExec(
                "buildkit", cmd: ["sh", "-c", "tr '\\0' '\\n' < /proc/1/environ"])
            #expect(
                environ.contains("BUILDKIT_TEST_MARKER=\(marker)"),
                "a BUILDKIT_ variable in the caller's environment reaches the shim: \(environ)")

            // The published daemon socket appears as a file on the host once
            // the relay is attached.
            var socketAppeared = false
            for _ in 0..<50 {
                if FileManager.default.fileExists(atPath: hostSocket) {
                    socketAppeared = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(socketAppeared, "the published buildkitd socket exists at \(hostSocket)")

            // Post-separator flags reach buildkitd's own argv verbatim.
            var cmdline = ""
            for _ in 0..<20 {
                cmdline =
                    (try? f.doExec(
                        "buildkit",
                        cmd: ["sh", "-c", "xargs -0 < /proc/$(pidof -s buildkitd)/cmdline"])) ?? ""
                if !cmdline.isEmpty { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(
                cmdline.contains("buildkitd") && cmdline.contains("--debug"),
                "buildkitd runs with the passed daemon flags: \(cmdline)")

            // The builder serves builds with all three knobs applied.
            let dir = try f.createTempDir()
            try f.createContext(
                dir: dir,
                dockerfile: """
                    FROM scratch
                    ENV SEED=expose
                    """)
            try f.build(tag: "test-expose:\(f.testID)", contextDir: dir)
        }
    }

    /// A second start with identical knobs keeps the running builder; a
    /// changed managed environment recreates it. Observed through a file
    /// in the builder's filesystem: a kept builder still has it, a
    /// recreated one boots without it.
    @Test func testBuilderStartIsStableUntilItsInputsChange() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { try? f.builderDelete(force: true) }

            let marker = "echo-\(f.testID)"
            try f.run(["builder", "start"], env: ["BUILDKIT_TEST_MARKER": marker]).check()
            try await f.waitForBuilderRunning()
            _ = try f.doExec("buildkit", cmd: ["touch", "/tmp/witness"])

            try f.run(["builder", "start"], env: ["BUILDKIT_TEST_MARKER": marker]).check()
            try await f.waitForBuilderRunning()
            let kept = try f.doExec(
                "buildkit", cmd: ["sh", "-c", "ls /tmp/witness 2>/dev/null || echo gone"])
            #expect(kept.contains("/tmp/witness"), "an unchanged start keeps the running builder: \(kept)")

            try f.run(["builder", "start"], env: ["BUILDKIT_TEST_MARKER": "\(marker)-changed"]).check()
            try await f.waitForBuilderRunning()
            let recreated = try f.doExec(
                "buildkit", cmd: ["sh", "-c", "ls /tmp/witness 2>/dev/null || echo gone"])
            #expect(recreated.contains("gone"), "a changed environment recreates the builder: \(recreated)")
        }
    }
}
