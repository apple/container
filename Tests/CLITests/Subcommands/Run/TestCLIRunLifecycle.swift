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

import Testing

class TestCLIRunLifecycle: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testRunFailureCleanup() throws {
        let name = getTestName()

        // try to create a container we know will fail
        let badArgs: [String] = [
            "--rm",
            "--user",
            name,
        ]
        #expect(throws: CLIError.self, "expect container to fail with invalid user") {
            try self.doLongRun(name: name, args: badArgs)
        }

        // try to create a container with the same name but no user that should succeed
        #expect(throws: Never.self, "expected container run to succeed") {
            try self.doLongRun(name: name, args: [])
            defer {
                try? self.doStop(name: name)
            }
            let _ = try self.doExec(name: name, cmd: ["date"])
            try self.doStop(name: name)
        }
    }

    @Test func testStartIdempotent() throws {
        let name = getTestName()

        #expect(throws: Never.self, "expected container run to succeed") {
            try self.doLongRun(name: name, args: [])
            defer {
                try? self.doStop(name: name)
            }
            try self.waitForContainerRunning(name)

            let (_, output, _, status) = try self.run(arguments: ["start", name])
            #expect(status == 0, "expected start to succeed on already running container")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == name, "expected output to be container name")

            // Don't care about the resp, just that the container is still there and not cleaned up.
            let _ = try inspectContainer(name)

            try self.doStop(name: name)
        }
    }

    @Test func testStartIdempotentAttachFails() throws {
        let name = getTestName()

        #expect(throws: Never.self, "expected container run to succeed") {
            try self.doLongRun(name: name, args: [])
            defer {
                try? self.doStop(name: name)
            }
            try self.waitForContainerRunning(name)

            let (_, _, error, status) = try self.run(arguments: ["start", "-a", name])
            #expect(status != 0, "expected start with attach to fail on already running container")
            #expect(error.contains("attach is currently unsupported on already running containers"), "expected error message about attach not supported")

            try self.doStop(name: name)
        }
    }

    /// Test that rapid stop+start doesn't auto-delete the container (issue #833)
    @Test func testRapidStopStartDoesNotDeleteContainer() throws {
        let name = getTestName()

        // Create container without autoRemove so it persists after stop
        try self.doLongRun(name: name, args: [], autoRemove: false)
        defer {
            try? self.doStop(name: name)
            try? self.doRemove(name: name, force: true)
        }
        try self.waitForContainerRunning(name)

        // Issue stop and start in rapid succession - this used to delete the container
        // because the sandbox was still shutting down when start was called
        let stopProcess = Process()
        stopProcess.executableURL = try executablePath
        stopProcess.arguments = ["stop", "-s", "SIGKILL", name]
        try stopProcess.run()
        // Don't wait for stop to complete - immediately try to start

        let (_, output, error, status) = try self.run(arguments: ["start", name])

        // The container should either start successfully (after waiting for shutdown)
        // or fail gracefully - but it should NOT be deleted
        if status != 0 {
            // If start failed, the container should still exist
            let inspectResult = try? self.inspectContainer(name)
            #expect(inspectResult != nil, "container should still exist after failed rapid start: \(error)")
        } else {
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == name, "start should output container name")
            // Verify container is running
            let containerStatus = try self.getContainerStatus(name)
            #expect(containerStatus == "running", "container should be running after rapid stop+start")
        }
    }
}
