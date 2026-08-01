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

@Suite
struct TestCLIExecCommand {
    @Test func testCreateExecCommand() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try f.doStart(name)
            try await f.waitForContainerRunning(name)
            let uname = try f.doExec(name, cmd: ["uname"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(uname == "Linux", "expected OS to be Linux, got \(uname)")
            try f.doStop(name)
        }
    }

    @Test func testExecDetach() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try f.doStart(name)
            try await f.waitForContainerRunning(name)

            let output = try f.doExec(name, cmd: ["sh", "-c", "touch /tmp/detach_test_marker"], detach: true)
            try #require(
                output.trimmingCharacters(in: .whitespacesAndNewlines) == name,
                "exec --detach should print the container name")

            let ls = try f.doExec(name, cmd: ["ls", "/"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(ls.contains("tmp"), "container should still be running after detached exec")

            // Retry until the detached process creates the marker file.
            var markerFound = false
            for _ in 0..<3 {
                let result = try f.run(["exec", name, "test", "-f", "/tmp/detach_test_marker"])
                if result.status == 0 {
                    markerFound = true
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            try #require(markerFound, "marker file should be created by detached process within 3 seconds")

            try f.doStop(name)
        }
    }

    @Test func testExecDetachProcessRunning() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            try f.doCreate(name: name, image: image)
            f.addCleanup { try? f.doStop(name) }
            try f.doStart(name)
            try await f.waitForContainerRunning(name)

            let output = try f.doExec(name, cmd: ["sleep", "10"], detach: true)
            try #require(
                output.trimmingCharacters(in: .whitespacesAndNewlines) == name,
                "exec --detach should print the container name")

            let ps = try f.doExec(name, cmd: ["ps", "aux"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(ps.contains("sleep 10"), "detached 'sleep 10' should appear in ps output")

            try f.doStop(name)
        }
    }

    @Test func testExecOnExitingContainer() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            // sh exits immediately in detached mode with no stdin; container stops on its own.
            try await f.doLongRun(name: name, image: image, containerArgs: ["sh"], autoRemove: false)
            f.addCleanup { try? f.doRemove(name) }
            try await Task.sleep(for: .seconds(1))

            try f.doStart(name)
            let execResult = try f.run(["exec", name, "sleep", "infinity"])
            if execResult.status != 0 {
                #expect(
                    execResult.error.contains("is not running")
                        || execResult.error.contains("failed to create process"),
                    "expected 'not running' error, got: \(execResult.error)")
            }

            try await Task.sleep(for: .seconds(1))
            // Container should still exist even if exec failed.
            _ = try f.getContainerStatus(name)
        }
    }
}
