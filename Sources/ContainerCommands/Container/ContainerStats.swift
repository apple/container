//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import Foundation

extension Application {
    public struct ContainerStats: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "stats",
            abstract: "Display resource usage statistics for containers")

        @Argument(help: "Container ID or name (optional, shows all running containers if not specified)")
        var containers: [String] = []

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .long, help: "Disable streaming stats and only pull the first result")
        var noStream = false

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            if format == .json || noStream {
                // Static mode - get stats once and exit
                try await runStatic()
            } else {
                // Streaming mode - continuously update like top
                // Enter alternate screen buffer and hide cursor
                print("\u{001B}[?1049h\u{001B}[?25l", terminator: "")
                fflush(stdout)

                defer {
                    // Exit alternate screen buffer and show cursor again
                    print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")
                    fflush(stdout)
                }

                try await runStreaming()
            }
        }

        private func runStatic() async throws {
            let allContainers = try await ClientContainer.list()

            let containersToShow: [ClientContainer]
            if containers.isEmpty {
                // No containers specified - show all running containers
                containersToShow = allContainers.filter { $0.status == .running }
            } else {
                // Validate all specified containers exist before proceeding
                var found: [ClientContainer] = []
                for containerId in containers {
                    guard let container = allContainers.first(where: { $0.id == containerId || $0.id.starts(with: containerId) }) else {
                        throw ContainerizationError(
                            .notFound,
                            message: "no such container: \(containerId)"
                        )
                    }
                    found.append(container)
                }
                containersToShow = found
            }

            let statsData = try await collectStats(for: containersToShow)

            if format == .json {
                let jsonStats = statsData.map { $0.stats2 }
                let data = try JSONEncoder().encode(jsonStats)
                print(String(data: data, encoding: .utf8)!)
                return
            }

            printStatsTable(statsData)
        }

        private func runStreaming() async throws {
            // If containers were specified, validate they all exist upfront
            if !containers.isEmpty {
                let allContainers = try await ClientContainer.list()
                for containerId in containers {
                    guard allContainers.first(where: { $0.id == containerId || $0.id.starts(with: containerId) }) != nil else {
                        throw ContainerizationError(
                            .notFound,
                            message: "no such container: \(containerId)"
                        )
                    }
                }
            }

            clearScreen()
            // Show header right away.
            printStatsTable([])

            while true {
                do {
                    let allContainers = try await ClientContainer.list()

                    let containersToShow: [ClientContainer]
                    if containers.isEmpty {
                        containersToShow = allContainers.filter { $0.status == .running }
                    } else {
                        var found: [ClientContainer] = []
                        for containerId in containers {
                            if let container = allContainers.first(where: { $0.id == containerId || $0.id.starts(with: containerId) }) {
                                found.append(container)
                            }
                        }
                        containersToShow = found
                    }

                    let statsData = try await collectStats(for: containersToShow)

                    // Clear screen and reprint
                    clearScreen()
                    printStatsTable(statsData)

                    if statsData.isEmpty {
                        try await Task.sleep(for: .seconds(2))
                    }
                } catch {
                    clearScreen()
                    print("error collecting stats: \(error)")
                    try await Task.sleep(for: .seconds(2))
                }
            }
        }

        private struct StatsSnapshot {
            let container: ClientContainer
            let stats1: ContainerResource.ContainerStats
            let stats2: ContainerResource.ContainerStats
        }

        private func collectStats(for containers: [ClientContainer]) async throws -> [StatsSnapshot] {
            var snapshots: [StatsSnapshot] = []

            // First sample
            for container in containers {
                guard container.status == .running else { continue }
                do {
                    let stats1 = try await container.stats()
                    snapshots.append(StatsSnapshot(container: container, stats1: stats1, stats2: stats1))
                } catch {
                    // Skip containers that error out
                    continue
                }
            }

            // Wait 2 seconds for CPU delta calculation
            if !snapshots.isEmpty {
                try await Task.sleep(for: .seconds(2))

                // Second sample
                for i in 0..<snapshots.count {
                    do {
                        let stats2 = try await snapshots[i].container.stats()
                        snapshots[i] = StatsSnapshot(
                            container: snapshots[i].container,
                            stats1: snapshots[i].stats1,
                            stats2: stats2
                        )
                    } catch {
                        // Keep the original stats if second sample fails
                        continue
                    }
                }
            }

            return snapshots
        }

        /// Calculate CPU percentage from two stat snapshots
        /// - Parameters:
        ///   - cpuUsageUsec1: CPU usage in microseconds from first sample
        ///   - cpuUsageUsec2: CPU usage in microseconds from second sample
        ///   - timeDeltaUsec: Time delta between samples in microseconds
        /// - Returns: CPU percentage where 100% = one fully utilized core
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

        private func printStatsTable(_ statsData: [StatsSnapshot]) {
            let headerRow = ["Container ID", "Cpu %", "Memory Usage", "Net Rx/Tx", "Block I/O", "Pids"]
            let notAvailable = "--"
            var rows = [headerRow]

            for snapshot in statsData {
                var row = [snapshot.container.id]
                let stats1 = snapshot.stats1
                let stats2 = snapshot.stats2

                if let cpuUsageUsec1 = stats1.cpuUsageUsec, let cpuUsageUsec2 = stats2.cpuUsageUsec {
                    let cpuPercent = Self.calculateCPUPercent(
                        cpuUsage1: .microseconds(cpuUsageUsec1),
                        cpuUsage2: .microseconds(cpuUsageUsec2),
                        timeInterval: .seconds(2)
                    )
                    let cpuStr = String(format: "%.2f%%", cpuPercent)
                    row.append(cpuStr)
                } else {
                    row.append(notAvailable)
                }

                let memUsageStr = stats2.memoryUsageBytes.map { Self.formatBytes($0) } ?? notAvailable
                let memLimitStr = stats2.memoryLimitBytes.map { Self.formatBytes($0) } ?? notAvailable
                row.append("\(memUsageStr) / \(memLimitStr)")

                let netRxStr = stats2.networkRxBytes.map { Self.formatBytes($0) } ?? notAvailable
                let netTxStr = stats2.networkTxBytes.map { Self.formatBytes($0) } ?? notAvailable
                row.append("\(netRxStr) / \(netTxStr)")

                let blkReadStr = stats2.blockReadBytes.map { Self.formatBytes($0) } ?? notAvailable
                let blkWriteStr = stats2.blockWriteBytes.map { Self.formatBytes($0) } ?? notAvailable
                row.append("\(blkReadStr) / \(blkWriteStr)")

                let pidsStr = stats2.numProcesses.map { "\($0)" } ?? notAvailable
                row.append(pidsStr)

                rows.append(row)
            }

            // Always print header, even if no containers
            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }

        private func clearScreen() {
            // Move cursor to home position and clear from cursor to end of screen
            print("\u{001B}[H\u{001B}[J", terminator: "")
            fflush(stdout)
        }
    }
}
