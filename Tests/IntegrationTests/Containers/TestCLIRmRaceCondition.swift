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

import ContainerResource
import ContainerTestSupport
import Foundation
import Testing

@Suite
struct TestCLIRmRaceCondition {
    @Test func testStaleInstanceTokenCannotDeleteReplacement() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-reuse"
            let otherName = "\(f.testID)-other"
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            f.addCleanup { try f.doRemoveIfExists(otherName, force: true, ignoreFailure: true) }

            let firstCreate = try createWithResult(f, name: name)
            let firstToken = firstCreate.instanceToken
            try f.run(["delete", "--if-instance-token", firstToken, name]).check()

            let replacementCreate = try createWithResult(f, name: name)
            let replacementToken = replacementCreate.instanceToken
            #expect(replacementToken != firstToken)

            let staleDelete = try f.run(["delete", "--if-instance-token", firstToken, name])
            #expect(staleDelete.status != 0)
            #expect(staleDelete.error.contains("container instance precondition failed"))
            #expect(try f.inspectContainer(name).configuration.instanceToken == replacementToken)

            let otherCreate = try createWithResult(f, name: otherName)
            let otherToken = otherCreate.instanceToken
            let crossContainerDelete = try f.run(["delete", "--if-instance-token", otherToken, name])
            #expect(crossContainerDelete.status != 0)
            #expect(try f.inspectContainer(name).configuration.instanceToken == replacementToken)

            try f.run(["delete", "--if-instance-token", replacementToken, name]).check()
            #expect((try f.run(["inspect", name])).status != 0)
        }
    }

    @Test func testConditionalForceDeleteChecksTokenBeforeStopping() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-force"
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }

            try await f.doLongRun(name: name, autoRemove: false, waitUntilRunning: true)
            let token = try #require(try f.inspectContainer(name).configuration.instanceToken)

            let mismatch = try f.run(["delete", "--force", "--if-instance-token", "stale-token", name])
            #expect(mismatch.status != 0)
            #expect(try f.getContainerStatus(name) == "running")

            try f.run(["delete", "--force", "--if-instance-token", token, name]).check()
            #expect((try f.run(["inspect", name])).status != 0)
        }
    }

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

    private func createWithResult(_ fixture: ContainerFixture, name: String) throws -> ContainerCreateResult {
        var args = ["create", "--format", "json", "--rm", "--name", name]
        args += fixture.proxyEnvironmentArgs
        args += [WarmupImage.alpine320.rawValue, "sleep", "infinity"]
        let command = try fixture.run(args).check()
        return try JSONDecoder().decode(ContainerCreateResult.self, from: command.outputData)
    }
}
