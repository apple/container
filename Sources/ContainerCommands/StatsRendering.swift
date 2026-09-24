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

import ContainerAPIClient
import ContainerResource
import ContainerizationOS
import Foundation

/// Shared sampling and rendering for the `stats` commands.
///
/// `container stats` (all running containers) and `container machine stats` (a
/// machine's backing container) display the same resource-usage columns,
/// derived from two samples taken `sampleInterval` apart. This type holds the
/// logic they share so the two commands stay in lockstep.
enum StatsRendering {
    /// A container's two stat samples plus the identifier to display for it.
    ///
    /// `id` is the label shown in the first table column — the container id for
    /// `container stats`, the machine id for `container machine stats` — which
    /// need not be the id the samples were collected under.
    struct Row: Sendable {
        let id: String
        let stats1: ContainerResource.ContainerStats
        let stats2: ContainerResource.ContainerStats
    }

    /// Time between the two samples used to derive the CPU percentage.
    static let sampleInterval: Duration = .seconds(2)

    /// Collects two samples for each container id, `sampleInterval` apart.
    ///
    /// Every id is sampled once, then — after a single wait — sampled again, so
    /// the interval is shared across ids rather than paid per id. Ids whose
    /// first sample fails are dropped; ids whose second sample fails keep the
    /// first sample for both (their CPU shows 0%).
    static func collect(client: ContainerClient, ids: [String]) async throws -> [Row] {
        var rows: [Row] = []

        // First sample.
        for id in ids {
            do {
                let stats1 = try await client.stats(id: id)
                rows.append(Row(id: id, stats1: stats1, stats2: stats1))
            } catch {
                // Skip ids that error out.
                continue
            }
        }

        // Wait once for the CPU delta, then take the second sample.
        if !rows.isEmpty {
            try await Task.sleep(for: sampleInterval)

            for i in 0..<rows.count {
                do {
                    let stats2 = try await client.stats(id: rows[i].id)
                    rows[i] = Row(id: rows[i].id, stats1: rows[i].stats1, stats2: stats2)
                } catch {
                    // Keep the first sample if the second one fails.
                    continue
                }
            }
        }

        return rows
    }

    /// Calculate CPU percentage from two cumulative CPU-time samples.
    /// - Parameters:
    ///   - cpuUsage1: cumulative CPU time at the first sample.
    ///   - cpuUsage2: cumulative CPU time at the second sample.
    ///   - timeInterval: wall-clock time between the two samples.
    /// - Returns: CPU percentage where 100% = one fully utilized core.
    static func calculateCPUPercent(
        cpuUsage1: Duration,
        cpuUsage2: Duration,
        timeInterval: Duration
    ) -> Double {
        let cpuDelta =
            cpuUsage2 > cpuUsage1
            ? cpuUsage2 - cpuUsage1
            : .seconds(0)
        return (cpuDelta / timeInterval) * 100.0
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let kib = 1024.0
        let mib = kib * 1024.0
        let gib = mib * 1024.0

        let value = Double(bytes)

        if value >= gib {
            return String(format: "%.2f GiB", value / gib)
        } else if value >= mib {
            return String(format: "%.2f MiB", value / mib)
        } else {
            return String(format: "%.2f KiB", value / kib)
        }
    }

    /// Renders the stats rows as a column-aligned table.
    ///
    /// `idHeader` names the first column (e.g. `"Container ID"` or
    /// `"Machine ID"`). The header row is always emitted, even with no rows.
    static func table(_ rows: [Row], idHeader: String) -> String {
        let headerRow = [idHeader, "Cpu %", "Memory Usage", "Net Rx/Tx", "Block I/O", "Pids"]
        let notAvailable = "--"
        var tableRows = [headerRow]

        for row in rows {
            var cells = [row.id]
            let stats1 = row.stats1
            let stats2 = row.stats2

            if let cpuUsageUsec1 = stats1.cpuUsageUsec, let cpuUsageUsec2 = stats2.cpuUsageUsec {
                let cpuPercent = calculateCPUPercent(
                    cpuUsage1: .microseconds(cpuUsageUsec1),
                    cpuUsage2: .microseconds(cpuUsageUsec2),
                    timeInterval: sampleInterval
                )
                cells.append(String(format: "%.2f%%", cpuPercent))
            } else {
                cells.append(notAvailable)
            }

            let memUsageStr = stats2.memoryUsageBytes.map { formatBytes($0) } ?? notAvailable
            let memLimitStr = stats2.memoryLimitBytes.map { formatBytes($0) } ?? notAvailable
            cells.append("\(memUsageStr) / \(memLimitStr)")

            let netRxStr = stats2.networkRxBytes.map { formatBytes($0) } ?? notAvailable
            let netTxStr = stats2.networkTxBytes.map { formatBytes($0) } ?? notAvailable
            cells.append("\(netRxStr) / \(netTxStr)")

            let blkReadStr = stats2.blockReadBytes.map { formatBytes($0) } ?? notAvailable
            let blkWriteStr = stats2.blockWriteBytes.map { formatBytes($0) } ?? notAvailable
            cells.append("\(blkReadStr) / \(blkWriteStr)")

            let pidsStr = stats2.numProcesses.map { "\($0)" } ?? notAvailable
            cells.append(pidsStr)

            tableRows.append(cells)
        }

        // Always print header, even if there are no rows.
        return TableOutput(rows: tableRows).format()
    }

    /// Renders one snapshot of stats in the requested format and returns.
    ///
    /// The machine-readable payload is each row's second sample (matching the
    /// table's metric columns); the derived CPU percentage appears only in the
    /// table.
    static func renderStatic(rows: [Row], format: ListFormat, idHeader: String) throws {
        // Encode each row's second sample, labeled with the row's display id so
        // the machine-readable output identifies rows the same way the table
        // does (the machine id for `container machine stats`). For
        // `container stats` the display id already equals the stats id, so this
        // is a no-op there.
        let payload = rows.map { row -> ContainerResource.ContainerStats in
            var stats = row.stats2
            stats.id = row.id
            return stats
        }
        try Output.render(payload: payload, format: format) {
            table(rows, idHeader: idHeader)
        }
    }

    /// Continuously renders stats like `top`, refreshing on each `fetch()`.
    ///
    /// Switches the terminal to the alternate screen buffer and hides the
    /// cursor, restoring both on exit — including on `SIGINT`/`SIGTERM`. `fetch`
    /// produces the rows for each frame.
    static func stream(idHeader: String, fetch: @Sendable @escaping () async throws -> [Row]) async throws {
        // Enter alternate screen buffer and hide cursor.
        print("\u{001B}[?1049h\u{001B}[?25l", terminator: "")
        fflush(stdout)

        defer {
            // Exit alternate screen buffer and show cursor again.
            print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")
            fflush(stdout)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                let handler = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM])
                for await _ in handler.signals {
                    throw CancellationError()
                }
            }
            group.addTask {
                clearScreen()
                // Show header right away.
                print(table([], idHeader: idHeader))

                while true {
                    do {
                        let rows = try await fetch()

                        // Clear screen and reprint.
                        clearScreen()
                        print(table(rows, idHeader: idHeader))

                        if rows.isEmpty {
                            try await Task.sleep(for: sampleInterval)
                        }
                    } catch {
                        clearScreen()
                        print("error collecting stats: \(error)")
                        try await Task.sleep(for: sampleInterval)
                    }
                }
            }
            do {
                try await group.next()
            } catch is CancellationError {
                // Normal exit on signal; defer restores the terminal.
            }
        }
    }

    private static func clearScreen() {
        // Move cursor to home position and clear from cursor to end of screen.
        print("\u{001B}[H\u{001B}[J", terminator: "")
        fflush(stdout)
    }
}
