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
struct TestCLIStatsCommand {
    @Test func testStatsNoStreamJSONFormat() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { name in
                let result = try f.run(["stats", "--format", "json", "--no-stream", name]).check()
                let stats = try JSONDecoder().decode([ContainerStats].self, from: result.outputData)
                #expect(stats.count == 1, "expected stats for one container")
                #expect(stats[0].id == name, "container ID should match")
                let memoryUsageBytes = try #require(stats[0].memoryUsageBytes)
                let numProcesses = try #require(stats[0].numProcesses)
                #expect(memoryUsageBytes > 0, "memory usage should be non-zero")
                #expect(numProcesses >= 1, "should have at least one process")
            }
        }
    }

    @Test func testStatsIdleCPUPercentage() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image, containerArgs: ["sleep", "3600"]) { name in
                let result = try f.run(["stats", "--no-stream", name]).check()
                let lines = result.output.components(separatedBy: .newlines)
                #expect(lines.count >= 2, "should have at least header and one data row")
                let dataLine = try #require(lines.first { $0.contains(name) }, "should find container data row")
                let columns = dataLine.split(separator: " ").filter { !$0.isEmpty }
                #expect(columns.count >= 2, "should have at least 2 columns")
                let cpuString = String(columns[1])
                #expect(cpuString.hasSuffix("%"), "CPU column should end with %")
                let cpuValue = try #require(Double(cpuString.dropLast()), "should parse CPU percentage")
                #expect(cpuValue < 5.0, "idle container CPU should be < 5%, got \(cpuValue)%")
            }
        }
    }

    @Test func testStatsHighCPUPercentage() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image, containerArgs: ["sh", "-c", "while true; do :; done"]) { name in
                let result = try f.run(["stats", "--no-stream", name]).check()
                let lines = result.output.components(separatedBy: .newlines)
                #expect(lines.count >= 2, "should have at least header and one data row")
                let dataLine = try #require(lines.first { $0.contains(name) }, "should find container data row")
                let columns = dataLine.split(separator: " ").filter { !$0.isEmpty }
                #expect(columns.count >= 2, "should have at least 2 columns")
                let cpuString = String(columns[1])
                #expect(cpuString.hasSuffix("%"), "CPU column should end with %")
                let cpuValue = try #require(Double(cpuString.dropLast()), "should parse CPU percentage")
                #expect(cpuValue > 50.0, "busy container CPU should be > 50%, got \(cpuValue)%")
                #expect(cpuValue < 150.0, "single busy loop should not exceed 150%, got \(cpuValue)%")
            }
        }
    }

    @Test func testStatsTableFormat() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image) { name in
                let result = try f.run(["stats", "--no-stream", name]).check()
                #expect(result.output.contains("Container ID"), "output should contain table header")
                #expect(result.output.contains("Cpu %"), "output should contain CPU column")
                #expect(result.output.contains("Memory Usage"), "output should contain Memory column")
                #expect(result.output.contains(name), "output should contain container name")
            }
        }
    }

    @Test func testStatsAllContainers() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            // Run two containers simultaneously so both appear in the global stats snapshot.
            try await f.withContainer(image: image, tag: "c1") { name1 in
                try await f.withContainer(image: image, tag: "c2") { name2 in
                    let result = try f.run(["stats", "--format", "json", "--no-stream"]).check()
                    let stats = try JSONDecoder().decode([ContainerStats].self, from: result.outputData)
                    try #require(stats.count >= 2, "should have stats for at least 2 containers")
                    let ids = stats.map { $0.id }
                    #expect(ids.contains(name1), "should include first container")
                    #expect(ids.contains(name2), "should include second container")
                }
            }
        }
    }

    @Test func testStatsNonExistentContainer() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["stats", "--no-stream", "nonexistent-container-xyz"])
            #expect(result.status != 0, "stats should fail for non-existent container")
        }
    }
}
