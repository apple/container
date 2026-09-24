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
import Foundation
import Testing

@Suite
struct TestCLIMachineStats {
    private let machineImage = "ghcr.io/linuxcontainers/alpine:3.20"

    @Test func testMachineStatsNoStreamJSONFormat() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)

            let result = try f.runMachine(["stats", "--no-stream", "--format", "json", name]).check()
            let stats = try JSONDecoder().decode([ContainerStats].self, from: result.outputData)
            #expect(stats.count == 1, "expected stats for one machine")
            // The machine-readable payload identifies the row by the machine id,
            // not the internal backing-container id.
            #expect(stats[0].id == name, "stats id should be the machine id")
            let memoryUsageBytes = try #require(stats[0].memoryUsageBytes)
            #expect(memoryUsageBytes > 0, "memory usage should be non-zero")
            let numProcesses = try #require(stats[0].numProcesses)
            #expect(numProcesses >= 1, "should have at least one process")
        }
    }

    @Test func testMachineStatsTableFormat() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineBoot(name: name)

            let result = try f.runMachine(["stats", "--no-stream", name]).check()
            #expect(result.output.contains("Machine ID"), "output should contain the machine table header")
            #expect(result.output.contains("Cpu %"), "output should contain the CPU column")
            #expect(result.output.contains("Memory Usage"), "output should contain the Memory column")
            #expect(result.output.contains(name), "output should contain the machine name")
        }
    }

    @Test func testMachineStatsNotRunning() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            // Created but never booted, so it is not running.
            try f.doMachineCreate(name: name, image: machineImage)

            let result = try f.runMachine(["stats", "--no-stream", name])
            #expect(result.status != 0, "stats should fail for a machine that is not running")
        }
    }

    @Test func testMachineStatsNonExistent() async throws {
        try await ContainerFixture.with { f in
            let result = try f.runMachine(["stats", "--no-stream", "nonexistent-machine-xyz"])
            #expect(result.status != 0, "stats should fail for a non-existent machine")
        }
    }
}
