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

@testable import ContainerCommands

private func makeSampleStats(
    id: String = "busy",
    memoryUsageBytes: UInt64? = 1024,
    memoryLimitBytes: UInt64? = 256 * 1024 * 1024,
    cpuUsageUsec: UInt64? = 2_000_000,
    networkRxBytes: UInt64? = 10,
    networkTxBytes: UInt64? = 20,
    blockReadBytes: UInt64? = 30,
    blockWriteBytes: UInt64? = 40,
    numProcesses: UInt64? = 1
) -> ContainerResource.ContainerStats {
    ContainerResource.ContainerStats(
        id: id,
        memoryUsageBytes: memoryUsageBytes,
        memoryLimitBytes: memoryLimitBytes,
        cpuUsageUsec: cpuUsageUsec,
        networkRxBytes: networkRxBytes,
        networkTxBytes: networkTxBytes,
        blockReadBytes: blockReadBytes,
        blockWriteBytes: blockWriteBytes,
        numProcesses: numProcesses
    )
}

private func jsonObject(from report: Application.ContainerStats.StatsReport) throws -> [String: Any] {
    let data = try JSONEncoder().encode(report)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct CalculateCPUPercentTests {
    @Test
    func oneCoreFullyUtilizedIs100Percent() {
        let percent = Application.ContainerStats.calculateCPUPercent(
            cpuUsage1: .seconds(0),
            cpuUsage2: .seconds(2),
            timeInterval: Application.ContainerStats.sampleInterval
        )
        #expect(percent == 100.0)
    }

    @Test
    func fourCoresSaturatedIs400Percent() {
        let percent = Application.ContainerStats.calculateCPUPercent(
            cpuUsage1: .seconds(0),
            cpuUsage2: .seconds(8),
            timeInterval: Application.ContainerStats.sampleInterval
        )
        #expect(percent == 400.0)
    }

    @Test
    func unchangedUsageIsZero() {
        let percent = Application.ContainerStats.calculateCPUPercent(
            cpuUsage1: .milliseconds(500),
            cpuUsage2: .milliseconds(500),
            timeInterval: Application.ContainerStats.sampleInterval
        )
        #expect(percent == 0.0)
    }

    @Test
    func usageDecreaseIsTreatedAsZero() {
        let percent = Application.ContainerStats.calculateCPUPercent(
            cpuUsage1: .seconds(4),
            cpuUsage2: .seconds(1),
            timeInterval: Application.ContainerStats.sampleInterval
        )
        #expect(percent == 0.0)
    }
}

struct StatsReportEncodingTests {
    @Test
    func jsonIncludesCpuPercentAndForwardsEverySampleField() throws {
        let stats = makeSampleStats()
        let report = Application.ContainerStats.StatsReport(stats: stats, cpuPercent: 42.5)
        let sample = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stats)) as? [String: Any]
        )
        let encoded = try jsonObject(from: report)

        for key in sample.keys {
            #expect(encoded[key] != nil, "StatsReport dropped sample field \(key)")
        }
        #expect(encoded["stats"] == nil, "sample should be flattened, not nested under stats")
        #expect(encoded["cpuPercent"] as? Double == 42.5)
        #expect(encoded["id"] as? String == "busy")

        let decoded = try JSONDecoder().decode(
            ContainerResource.ContainerStats.self,
            from: JSONEncoder().encode(report)
        )
        #expect(decoded.id == stats.id)
        #expect(decoded.memoryUsageBytes == stats.memoryUsageBytes)
        #expect(decoded.cpuUsageUsec == stats.cpuUsageUsec)
    }

    @Test
    func jsonOmitsNilCpuPercent() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuPercent: nil)
        let encoded = try jsonObject(from: report)
        #expect(encoded["cpuPercent"] == nil)
        #expect(encoded["id"] as? String == "busy")
    }

    @Test
    func renderJSONIncludesCpuPercent() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuPercent: 12.25)
        let json = try Output.renderJSON([report])
        #expect(json.contains("\"cpuPercent\":12.25"))
        #expect(json.contains("\"id\":\"busy\""))
    }

    @Test
    func renderYAMLIncludesCpuPercent() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuPercent: 12.25)
        let yaml = try Output.renderYAML([report])
        #expect(yaml.contains("cpuPercent"))
        #expect(yaml.contains("busy"))
        #expect(yaml.contains("memoryUsageBytes"))
    }

    @Test
    func renderTOMLIncludesCpuPercent() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuPercent: 12.25)
        let toml = try Output.renderTOML([report])
        #expect(toml.contains("cpuPercent"))
        #expect(toml.contains("12.25"))
        #expect(toml.contains("busy"))
        #expect(toml.contains("memoryUsageBytes"))
    }
}
