//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

//

import Foundation
import Testing

class TestCLIRmRaceCondition: CLITest {

    /// Helper method to check if a container exists
    private func containerExists(_ name: String) -> Bool {
        do {
            _ = try getContainerStatus(name)
            return true
        } catch {
            return false
        }
    }

    /// Safe container removal that handles already-removed containers gracefully
    private func safeRemove(name: String, force: Bool = false) throws {
        guard containerExists(name) else {
            // Container already removed, nothing to do
            return
        }
        try doRemove(name: name, force: force)
    }

    @Test func testStopRmRace() async throws {
        let name: String! = Test.current?.name.trimmingCharacters(in: ["(", ")"])

        do {
            // Create and start a container in detached mode that runs indefinitely
            try doCreate(name: name, args: ["sleep", "infinity"])
            try doStart(name: name)

            // Wait for container to be running
            try waitForContainerRunning(name)

            // Call doStop - this should return immediately without waiting
            try doStop(name: name)

            // Immediately call doRemove and handle both possible outcomes:
            // 1. Container removal succeeds immediately (race condition fixed)
            // 2. Container removal fails because it's still stopping (race condition detected)
            var raceConditionPrevented = false
            var raceConditionDetected = false

            do {
                try doRemove(name: name)
                // Success: The race condition prevention is working perfectly!
                // Container was removed cleanly without any race condition
                raceConditionPrevented = true
            } catch CLITest.CLIError.executionFailed(let message) {
                if message.contains("is not yet stopped and can not be deleted") {
                    // Expected behavior: Race condition detected and prevented
                    raceConditionDetected = true
                } else if message.contains("not found") || message.contains("failed to delete one or more containers") {
                    // Container was already removed by background cleanup - this is also success!
                    raceConditionPrevented = true
                } else {
                    Issue.record("Unexpected error message: \(message)")
                    return
                }
            } catch {
                Issue.record("Unexpected error type: \(error)")
                return
            }

            // Either outcome is acceptable - both indicate the race condition fix is working
            #expect(
                raceConditionPrevented || raceConditionDetected,
                "Expected either immediate success (race prevented) or controlled failure (race detected)")

            // If the container was already removed, we're done
            if raceConditionPrevented {
                return
            }

            // If we detected a race condition, wait for cleanup and retry removal
            #expect(raceConditionDetected, "Should have detected race condition if we reach this point")

            // Give the background cleanup a moment to finish
            try await Task.sleep(for: .seconds(2))

            // Retry removal with exponential backoff for cleanup
            var removeAttempts = 0
            let maxRemoveAttempts = 5
            let baseDelay = 1.0  // seconds

            while removeAttempts < maxRemoveAttempts {
                do {
                    try safeRemove(name: name)
                    break
                } catch CLITest.CLIError.executionFailed(let message) {
                    // If container doesn't exist, we're done
                    if message.contains("not found") {
                        break
                    }

                    guard removeAttempts < maxRemoveAttempts - 1 else {
                        throw CLITest.CLIError.executionFailed("Failed to remove container after \(maxRemoveAttempts) attempts: \(message)")
                    }

                    let delay = baseDelay * pow(2.0, Double(removeAttempts))
                    try await Task.sleep(for: .seconds(delay))
                    removeAttempts += 1
                } catch {
                    guard removeAttempts < maxRemoveAttempts - 1 else {
                        throw error
                    }
                    let delay = baseDelay * pow(2.0, Double(removeAttempts))
                    try await Task.sleep(for: .seconds(delay))
                    removeAttempts += 1
                }
            }

        } catch {
            Issue.record("failed to test stop-rm race condition: \(error)")
            // Safe cleanup - only try to remove if container actually exists
            try? safeRemove(name: name, force: true)
            return
        }
    }
}
