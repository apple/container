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
struct TestCLIRmRaceCondition {
    @Test func testStopRmRace() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-c"
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }

            try f.doCreate(name: name)
            try f.doStart(name)
            try await f.waitForContainerRunning(name)
            try f.doStop(name)

            // Immediately attempt removal — both outcomes are valid:
            // 1. Success: race condition prevention working perfectly
            // 2. "not yet stopped" error: race detected and controlled
            var raceConditionPrevented = false
            var raceConditionDetected = false

            do {
                try f.doRemove(name)
                raceConditionPrevented = true
            } catch CommandError.nonZeroExit(_, let message) {
                if message.contains("is not yet stopped and can not be deleted") {
                    raceConditionDetected = true
                } else if message.contains("not found")
                    || message.contains("failed to delete one or more containers")
                {
                    raceConditionPrevented = true
                } else {
                    Issue.record("Unexpected error message: \(message)")
                    return
                }
            } catch {
                Issue.record("Unexpected error type: \(error)")
                return
            }

            #expect(
                raceConditionPrevented || raceConditionDetected,
                "Expected either immediate success (race prevented) or controlled failure (race detected)"
            )

            if raceConditionPrevented { return }

            // Race detected — wait for background cleanup then retry.
            try await Task.sleep(for: .seconds(2))

            try await f.retry(attempts: 5, delay: .seconds(3)) {
                guard (try? f.getContainerStatus(name)) != nil else { return true }
                do {
                    try f.doRemove(name)
                    return true
                } catch CommandError.nonZeroExit(_, let message) where message.contains("not found") {
                    return true
                } catch {
                    return false
                }
            }
        }
    }
}
