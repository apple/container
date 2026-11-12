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

private func makeContainerSnapshot(id: String = "busy") -> ContainerSnapshot {
    let image = ImageDescription(
        reference: "docker.io/library/alpine:latest",
        descriptor: .init(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:" + String(repeating: "0", count: 64),
            size: 0
        )
    )
    let process = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0),
        supplementalGroups: [],
        rlimits: []
    )
    let configuration = ContainerConfiguration(id: id, image: image, process: process)
    return ContainerSnapshot(configuration: configuration, status: .running, networks: [])
}

private func jsonObject(from report: Application.ContainerStats.StatsReport) throws -> [String: Any] {
    let data = try JSONEncoder().encode(report)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct CalculateCPUUtilizationTests {
    @Test
    func oneCoreFullyUtilizedIsOne() {
        let utilization = Application.ContainerStats.calculateCPUUtilization(
            cpuUsage1: .seconds(0),
            cpuUsage2: .seconds(2),
            timeInterval: .seconds(2)
        )
        #expect(utilization == 1.0)
    }

    @Test
    func fourCoresSaturatedIsFour() {
        let utilization = Application.ContainerStats.calculateCPUUtilization(
            cpuUsage1: .seconds(0),
            cpuUsage2: .seconds(8),
            timeInterval: .seconds(2)
        )
        #expect(utilization == 4.0)
    }

    @Test
    func dividesByTheMeasuredInterval() {
        let utilization = Application.ContainerStats.calculateCPUUtilization(
            cpuUsage1: .seconds(0),
            cpuUsage2: .seconds(2),
            timeInterval: .milliseconds(2500)
        )
        #expect(utilization == 0.8)
    }

    @Test
    func unchangedUsageIsZero() {
        let utilization = Application.ContainerStats.calculateCPUUtilization(
            cpuUsage1: .milliseconds(500),
            cpuUsage2: .milliseconds(500),
            timeInterval: .seconds(2)
        )
        #expect(utilization == 0.0)
    }

    @Test
    func usageDecreaseIsTreatedAsZero() {
        let utilization = Application.ContainerStats.calculateCPUUtilization(
            cpuUsage1: .seconds(4),
            cpuUsage2: .seconds(1),
            timeInterval: .seconds(2)
        )
        #expect(utilization == 0.0)
    }
}

struct StatsSnapshotTests {
    private let start = ContinuousClock.now

    private func makeSnapshot(
        cpuUsageUsec1: UInt64?,
        cpuUsageUsec2: UInt64?,
        elapsed: Duration
    ) -> Application.ContainerStats.StatsSnapshot {
        Application.ContainerStats.StatsSnapshot(
            container: makeContainerSnapshot(),
            stats1: makeSampleStats(cpuUsageUsec: cpuUsageUsec1),
            sampledAt1: start,
            stats2: makeSampleStats(cpuUsageUsec: cpuUsageUsec2),
            sampledAt2: start.advanced(by: elapsed)
        )
    }

    @Test
    func utilizationUsesTheMeasuredInterval() {
        let snapshot = makeSnapshot(cpuUsageUsec1: 0, cpuUsageUsec2: 2_000_000, elapsed: .milliseconds(2500))
        #expect(snapshot.cpuUtilization == 0.8)
    }

    @Test
    func utilizationIsNilWithoutASecondSample() {
        let snapshot = makeSnapshot(cpuUsageUsec1: 1_000_000, cpuUsageUsec2: 1_000_000, elapsed: .zero)
        #expect(snapshot.cpuUtilization == nil)
    }

    @Test
    func utilizationIsNilWhenTheFirstSampleHasNoCPUUsage() {
        let snapshot = makeSnapshot(cpuUsageUsec1: nil, cpuUsageUsec2: 2_000_000, elapsed: .seconds(2))
        #expect(snapshot.cpuUtilization == nil)
    }

    @Test
    func utilizationIsNilWhenTheSecondSampleHasNoCPUUsage() {
        let snapshot = makeSnapshot(cpuUsageUsec1: 0, cpuUsageUsec2: nil, elapsed: .seconds(2))
        #expect(snapshot.cpuUtilization == nil)
    }

    @Test
    func reportOmitsCpuUtilizationWithoutASecondSample() throws {
        let snapshot = makeSnapshot(cpuUsageUsec1: 1_000_000, cpuUsageUsec2: 1_000_000, elapsed: .zero)
        let encoded = try jsonObject(from: Application.ContainerStats.StatsReport(snapshot: snapshot))
        #expect(encoded["cpuUtilization"] == nil)
        #expect(encoded["id"] as? String == "busy")
    }
}

struct StatsReportEncodingTests {
    @Test
    func jsonIncludesCpuUtilizationAndForwardsEverySampleField() throws {
        let stats = makeSampleStats()
        let report = Application.ContainerStats.StatsReport(stats: stats, cpuUtilization: 0.425)
        let sample = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stats)) as? [String: Any]
        )
        let encoded = try jsonObject(from: report)

        for key in sample.keys {
            #expect(encoded[key] != nil, "StatsReport dropped sample field \(key)")
        }
        #expect(encoded["stats"] == nil, "sample should be flattened, not nested under stats")
        #expect(encoded["cpuUtilization"] as? Double == 0.425)
        #expect(encoded["cpuPercent"] == nil, "percentages are a table-only presentation")
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
    func jsonOmitsNilCpuUtilization() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuUtilization: nil)
        let encoded = try jsonObject(from: report)
        #expect(encoded["cpuUtilization"] == nil)
        #expect(encoded["id"] as? String == "busy")
    }

    @Test
    func renderJSONIncludesCpuUtilization() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuUtilization: 0.125)
        let json = try Output.renderJSON([report])
        #expect(json.contains("\"cpuUtilization\":0.125"))
        #expect(json.contains("\"id\":\"busy\""))
    }

    @Test
    func renderYAMLIncludesCpuUtilization() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuUtilization: 0.125)
        let yaml = try Output.renderYAML([report])
        #expect(yaml.contains("cpuUtilization"))
        #expect(yaml.contains("busy"))
        #expect(yaml.contains("memoryUsageBytes"))
    }

    @Test
    func renderTOMLIncludesCpuUtilization() throws {
        let report = Application.ContainerStats.StatsReport(stats: makeSampleStats(), cpuUtilization: 0.125)
        let toml = try Output.renderTOML([report])
        #expect(toml.contains("cpuUtilization"))
        #expect(toml.contains("0.125"))
        #expect(toml.contains("busy"))
        #expect(toml.contains("memoryUsageBytes"))
    }
}
