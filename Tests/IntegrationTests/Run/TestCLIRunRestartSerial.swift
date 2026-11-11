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

/// Restart policy tests. Serial because they depend on backoff and stability timing.
@Suite(.serialized)
struct TestCLIRunRestartSerial {
    // Run a container that exits with the given code on first run, then sleeps forever on restart.
    // This allows waitForContainerRunning to reliably catch the restarted container.
    private func runWithRestartOnce(_ f: ContainerFixture, name: String, policy: String, exitCode: Int) async throws {
        try await f.doLongRun(
            name: name,
            args: ["--restart", policy],
            containerArgs: ["sh", "-c", "if [ ! -f /tmp/restarted ]; then touch /tmp/restarted; exit \(exitCode); else sleep infinity; fi"],
            autoRemove: false
        )
        f.addCleanup { try? f.doRemove(name, force: true) }
    }

    private func doKill(_ f: ContainerFixture, _ name: String) throws {
        try f.run(["kill", "-s", "SIGKILL", name]).check()
    }

    @Test func testRestartNo() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            try await runWithRestartOnce(f, name: name, policy: "no", exitCode: 0)

            // Give a moment for any (unexpected) restart to occur
            try await Task.sleep(for: .seconds(3))

            let status = try f.getContainerStatus(name)
            #expect(status == "stopped", "expected container with restart policy 'no' to remain stopped, got '\(status)'")
        }
    }

    @Test func testRestartOnFailure() async throws {
        try await ContainerFixture.with { f in
            let failing = "\(f.testID)-exit-fail"

            // Non-zero exit: should restart
            try await runWithRestartOnce(f, name: failing, policy: "onFailure", exitCode: 1)

            // Give time for container to restart
            try await Task.sleep(for: .seconds(3))

            try await f.waitForContainerRunning(failing)
            var status = try f.getContainerStatus(failing)
            #expect(status == "running", "expected container with 'onFailure' policy to restart after non-zero exit, got '\(status)'")

            try doKill(f, failing)
            try await Task.sleep(for: .seconds(3))

            status = try f.getContainerStatus(failing)
            #expect(status == "stopped", "expected container with 'onFailure' policy to not restart after manual stop, got '\(status)'")

            let succeeding = "\(f.testID)-exit-succeed"
            try await runWithRestartOnce(f, name: succeeding, policy: "onFailure", exitCode: 0)

            try await Task.sleep(for: .seconds(3))
            status = try f.getContainerStatus(succeeding)
            #expect(status == "stopped", "expected container with 'onFailure' policy to not restart after zero exit, got '\(status)'")
        }
    }

    @Test func testRestartAlways() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            try await runWithRestartOnce(f, name: name, policy: "always", exitCode: 0)

            // Give time for container to restart
            try await Task.sleep(for: .seconds(3))

            try await f.waitForContainerRunning(name)
            var status = try f.getContainerStatus(name)
            #expect(status == "running", "expected container with 'always' policy to restart after zero exit, got '\(status)'")

            try doKill(f, name)
            try await Task.sleep(for: .seconds(3))

            status = try f.getContainerStatus(name)
            #expect(status == "stopped", "expected container with 'always' policy to not restart after manual stop, got '\(status)'")
        }
    }

    @Test func testRestartMultiple() async throws {
        try await ContainerFixture.with { f in
            // Multiple containers restarting must not block each other
            let name1 = "\(f.testID)-1"
            let name2 = "\(f.testID)-2"

            try await runWithRestartOnce(f, name: name1, policy: "always", exitCode: 1)
            try await runWithRestartOnce(f, name: name2, policy: "always", exitCode: 1)
            f.addCleanup {
                try? f.doStop(name1)
                try? f.doStop(name2)
            }

            // Both should restart independently without blocking each other
            try await f.waitForContainerRunning(name1)
            try await f.waitForContainerRunning(name2)

            let status1 = try f.getContainerStatus(name1)
            let status2 = try f.getContainerStatus(name2)
            #expect(status1 == "running", "expected container1 to be running, got '\(status1)'")
            #expect(status2 == "running", "expected container2 to be running, got '\(status2)'")
        }
    }

    @Test func testBackOff() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"

            try await f.doLongRun(
                name: name,
                args: ["--restart", "always"],
                containerArgs: ["sh", "-c", "sleep 1; exit 1;"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(name)
                try? f.doRemove(name, force: true)
            }

            // Poll until running (first restart)
            var samples: [Bool] = []
            for _ in 0..<30 {
                samples.append((try? f.getContainerStatus(name)) == "running")
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(samples.contains(true), "container did not restart for the first time")

            // If backOff is doubling correctly, the gap between restarts grows each cycle.
            // With 500ms polling and 1s sleep-before-exit per cycle, the backOff doubling
            // (100ms -> 200ms -> 400ms -> 800ms -> ...) means consecutive false runs grow longer.
            // The maximum run of consecutive false samples must be at least 4.
            var maxConsecutiveFalse = 0
            var currentRun = 0
            for sample in samples {
                if !sample {
                    currentRun += 1
                    maxConsecutiveFalse = max(maxConsecutiveFalse, currentRun)
                } else {
                    currentRun = 0
                }
            }
            #expect(maxConsecutiveFalse >= 4, "expected backOff to cause at least 4 consecutive stopped samples, got \(maxConsecutiveFalse)")
        }
    }

    @Test func testStabilityCall() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"

            // Each run increments a counter by appending a line to /tmp/count.
            // On run 8, backOff has accumulated to 10s (capped); the container then sleeps 12s
            // to stay alive past the stabilityCall window, which resets backOff to nil.
            //
            // BackOff sequence: 100ms, 200ms, 400ms, 800ms, 1.6s, 3.2s, 6.4s, 10s (cap)
            // Total expected wait: (1+0.1)+(1+0.2)+(1+0.4)+(1+0.8)+(1+1.6)+(1+3.2)+(1+6.4)+(1+10)+12+0.5 ~= 43.2s
            try await f.doLongRun(
                name: name,
                args: ["--restart", "always"],
                containerArgs: [
                    "sh", "-c",
                    "echo x >> /tmp/count; n=$(wc -l < /tmp/count); if [ \"$n\" -ge 8 ]; then sleep 12; fi; exit 1",
                ],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(name)
                try? f.doRemove(name, force: true)
            }

            // Wait for all 8 cycles + stability window + a small buffer.
            try await Task.sleep(for: .seconds(45))

            // At this point run 8 has slept 12s, triggering stabilityCall and resetting backOff.
            // The container should be running (restarted quickly after backOff reset).
            let status = try f.getContainerStatus(name)
            #expect(status == "running", "expected container to be running after stabilityCall reset backOff, got '\(status)'")
        }
    }
}
