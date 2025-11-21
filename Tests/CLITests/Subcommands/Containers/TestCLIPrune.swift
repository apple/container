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

@Suite(.serialized)
class TestCLIPruneCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testContainerPruneNoContainers() throws {
        let (_, output, error, status) = try run(arguments: ["prune"])
        if status != 0 {
            throw CLIError.executionFailed("container prune failed: \(error)")
        }

        #expect(output.contains("Reclaimed Zero KB in disk space"), "should show no containers message")
    }

    @Test func testContainerPruneStoppedContainers() throws {
        let testName = getTestName()
        let npcName = "\(testName)_wont_be_pruned"
        let pc0Name = "\(testName)_pruned_0"
        let pc1Name = "\(testName)_pruned_1"

        try doLongRun(name: npcName, containerArgs: ["sleep", "3600"], autoRemove: true)
        try doLongRun(name: pc0Name, containerArgs: ["sleep", "3600"], autoRemove: false)
        try doLongRun(name: pc1Name, containerArgs: ["sleep", "3600"], autoRemove: false)
        defer {
            try? doStop(name: npcName)
            try? doStop(name: pc0Name)
            try? doStop(name: pc1Name)
            try? doRemove(name: npcName)
            try? doRemove(name: pc0Name)
            try? doRemove(name: pc1Name)
        }
        try waitForContainerRunning(npcName)
        try waitForContainerRunning(pc0Name)
        try waitForContainerRunning(pc1Name)

        try doStop(name: pc0Name)
        try doStop(name: pc1Name)

        let pc0Id = try getContainerId(pc0Name)
        let pc1Id = try getContainerId(pc1Name)

        // Poll status until both containers are stopped, with interval checks and a timeout to avoid infinite loop
        let start = Date()
        let timeout: TimeInterval = 30  // seconds
        while true {
            let s0 = try getContainerStatus(pc0Name)
            let s1 = try getContainerStatus(pc1Name)
            if s0 == "stopped" && s1 == "stopped" { break }
            if Date().timeIntervalSince(start) > timeout {
                throw CLIError.executionFailed("Timeout waiting for containers to stop: pc0=\(s0), pc1=\(s1)")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let (_, output, error, status) = try run(arguments: ["prune"])

        if status != 0 {
            throw CLIError.executionFailed("container prune failed: \(error)")
        }

        #expect(output.contains(pc0Id) && output.contains(pc1Id), "should show the stopped containers id")
        #expect(!output.contains("Reclaimed Zero KB in disk space"), "reclaimed spaces should not Zero KB")

        let checkStatus = try getContainerStatus(npcName)
        #expect(checkStatus == "running", "not pruned container should still be running")
    }
}
