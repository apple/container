//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

class TestCLIExecCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testCreateExecCommand() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            var unameActual = try doExec(name: name, cmd: ["uname"])
            unameActual = unameActual.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(unameActual == "Linux", "expected OS to be Linux, instead got \(unameActual)")
            try doStop(name: name)
        } catch {
            Issue.record("failed to exec in container \(error)")
            return
        }
    }

    @Test func testExecDetach() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)

            // Run a long-running process in detached mode
            let output = try doExec(name: name, cmd: ["sh", "-c", "touch /tmp/detach_test_marker"], detach: true)
            let containerIdOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(containerIdOutput == name, "exec --detach should print the container ID")

            // Verify the detached process is running by checking if we can still exec commands
            var lsActual = try doExec(name: name, cmd: ["ls", "/"])
            lsActual = lsActual.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(lsActual.contains("tmp"), "container should still be running and accepting exec commands")

            // Retry loop to check if the marker file was created by the detached process
            var markerFound = false
            for _ in 0..<3 {
                let (_, _, _, status) = try run(arguments: [
                    "exec",
                    name,
                    "test", "-f", "/tmp/detach_test_marker",
                ])
                if status == 0 {
                    markerFound = true
                    break
                }
                sleep(1)
            }
            try #require(markerFound, "marker file should be created by detached process within 3 seconds")

            try doStop(name: name)
        } catch {
            Issue.record("failed to exec with detach in container \(error)")
            return
        }
    }

    @Test func testExecDetachProcessRunning() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)

            // Run a long-running process in detached mode
            let output = try doExec(name: name, cmd: ["sleep", "10"], detach: true)
            let containerIdOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(containerIdOutput == name, "exec --detach should print the container ID")

            // Immediately check if the process is running using ps
            var psOutput = try doExec(name: name, cmd: ["ps", "aux"])
            psOutput = psOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(psOutput.contains("sleep 10"), "detached process 'sleep 10' should be visible in ps output")

            try doStop(name: name)
        } catch {
            Issue.record("failed to verify detached process is running \(error)")
            return
        }
    }

    @Test func testExecOnExitingContainer() throws {
        do {
            let name = getTestName()
            try doLongRun(name: name, containerArgs: ["sh"], autoRemove: false)
            defer {
                try? doRemove(name: name)
            }
            // Give time for container process to exit due to no stdin
            sleep(1)

            try doStart(name: name)
            do {
                _ = try doExec(name: name, cmd: ["sleep", "infinity"])
            } catch CLIError.executionFailed(let message) {
                // There's no nice way to check fail reason here
                #expect(message.contains("is not running"), "expected container is not running if exec failed")
            }

            // Give time for the exec (or start) error handling settles down
            sleep(1)
            #expect(throws: Never.self, "expected the container remains") {
                try getContainerStatus(name)
            }
        }
    }
}
