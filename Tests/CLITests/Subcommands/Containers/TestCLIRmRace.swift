//===----------------------------------------------------------------------===//
// Copyright © none Apple Inc. and the container project authors. All rights reserved.
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

            // Immediately call doRemove and assert that it throws an error
            var didThrowExpectedError = false
            do {
                try doRemove(name: name)
            } catch CLITest.CLIError.executionFailed(let message) {
                if message.contains("container is not yet stopped and can not be deleted") {
                    didThrowExpectedError = true
                } else {
                    Issue.record("Unexpected error message: \(message)")
                }
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }

            #expect(didThrowExpectedError, "Expected doRemove to fail with 'container is not yet stopped and can not be deleted'")

            // Give the background cleanup a moment to finish
            try await Task.sleep(for: .seconds(2))

            // Call doRemove again - this should succeed
            try doRemove(name: name)

        } catch {
            Issue.record("failed to test stop-rm race condition: \(error)")
            // Try to clean up if something went wrong
            try? doRemove(name: name, force: true)
            return
        }
    }
}
