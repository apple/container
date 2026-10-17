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
import Testing

@testable import ContainerCommands

struct StatsRenderingFormatBytesTests {
    @Test
    func bytesBelowOneKiBStillRenderAsKiB() {
        #expect(StatsRendering.formatBytes(0) == "0.00 KiB")
        #expect(StatsRendering.formatBytes(512) == "0.50 KiB")
    }

    @Test
    func unitBoundaries() {
        #expect(StatsRendering.formatBytes(1024) == "1.00 KiB")
        #expect(StatsRendering.formatBytes(1024 * 1024) == "1.00 MiB")
        #expect(StatsRendering.formatBytes(1024 * 1024 * 1024) == "1.00 GiB")
    }

    @Test
    func fractionalUnits() {
        #expect(StatsRendering.formatBytes(1536) == "1.50 KiB")
        #expect(StatsRendering.formatBytes(1024 * 1024 * 3 / 2) == "1.50 MiB")
    }
}

struct StatsRenderingCPUPercentTests {
    @Test
    func zeroWhenNoDelta() {
        #expect(
            StatsRendering.calculateCPUPercent(
                cpuUsage1: .seconds(1), cpuUsage2: .seconds(1), timeInterval: .seconds(2)) == 0.0)
    }

    @Test
    func clampsNegativeDeltaToZero() {
        #expect(
            StatsRendering.calculateCPUPercent(
                cpuUsage1: .seconds(2), cpuUsage2: .seconds(1), timeInterval: .seconds(2)) == 0.0)
    }

    @Test
    func oneFullyUsedCoreIsOneHundredPercent() {
        #expect(
            StatsRendering.calculateCPUPercent(
                cpuUsage1: .seconds(0), cpuUsage2: .seconds(2), timeInterval: .seconds(2)) == 100.0)
    }

    @Test
    func halfUsedCoreIsFiftyPercent() {
        #expect(
            StatsRendering.calculateCPUPercent(
                cpuUsage1: .seconds(0), cpuUsage2: .seconds(1), timeInterval: .seconds(2)) == 50.0)
    }

    @Test
    func multipleCoresExceedOneHundredPercent() {
        #expect(
            StatsRendering.calculateCPUPercent(
                cpuUsage1: .seconds(0), cpuUsage2: .seconds(4), timeInterval: .seconds(2)) == 200.0)
    }
}

struct StatsRenderingTableTests {
    private func makeStats(
        cpuUsec: UInt64?,
        memUsage: UInt64? = nil,
        memLimit: UInt64? = nil,
        rx: UInt64? = nil,
        tx: UInt64? = nil,
        blockRead: UInt64? = nil,
        blockWrite: UInt64? = nil,
        pids: UInt64? = nil
    ) -> ContainerStats {
        ContainerStats(
            id: "backing-container",
            memoryUsageBytes: memUsage,
            memoryLimitBytes: memLimit,
            cpuUsageUsec: cpuUsec,
            networkRxBytes: rx,
            networkTxBytes: tx,
            blockReadBytes: blockRead,
            blockWriteBytes: blockWrite,
            numProcesses: pids)
    }

    @Test
    func headerUsesProvidedIdColumnLabelAndPrintsWithNoRows() {
        let out = StatsRendering.table([], idHeader: "Machine ID")
        #expect(out.contains("Machine ID"))
        #expect(out.contains("Cpu %"))
        #expect(out.contains("Memory Usage"))
        #expect(out.contains("Net Rx/Tx"))
        #expect(out.contains("Block I/O"))
        #expect(out.contains("Pids"))
        // Header only: a single line, no data rows.
        #expect(out.split(separator: "\n").count == 1)
    }

    @Test
    func rowRendersDisplayIdAndFormattedMetrics() {
        // 2s of CPU time over the 2s sample interval == one saturated core.
        let sample1 = makeStats(cpuUsec: 0)
        let sample2 = makeStats(
            cpuUsec: 2_000_000,
            memUsage: 1024 * 1024,
            memLimit: 2 * 1024 * 1024,
            rx: 0, tx: 0, blockRead: 0, blockWrite: 0,
            pids: 5)
        let out = StatsRendering.table(
            [.init(id: "my-machine", stats1: sample1, stats2: sample2)],
            idHeader: "Machine ID")
        #expect(out.contains("my-machine"))  // display id, not the container id
        #expect(out.contains("100.00%"))
        #expect(out.contains("1.00 MiB / 2.00 MiB"))
        #expect(out.contains("5"))  // pids
    }

    @Test
    func missingMetricsRenderAsDashes() {
        let sample = makeStats(cpuUsec: nil)
        let out = StatsRendering.table(
            [.init(id: "m", stats1: sample, stats2: sample)],
            idHeader: "Machine ID")
        #expect(out.contains("--"))
    }
}
