//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import ContainerClient
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

        @Flag(name: .long, help: "Display detailed I/O statistics (IOPS, latency, fsync, queue depth)")
        var io = false

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
            let stats1: ContainerClient.ContainerStats
            let stats2: ContainerClient.ContainerStats
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
            cpuUsageUsec1: UInt64,
            cpuUsageUsec2: UInt64,
            timeDeltaUsec: UInt64
        ) -> Double {
            let cpuDelta =
                cpuUsageUsec2 > cpuUsageUsec1
                ? cpuUsageUsec2 - cpuUsageUsec1
                : 0
            return (Double(cpuDelta) / Double(timeDeltaUsec)) * 100.0
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
            if io {
                printIOStatsTable(statsData)
            } else {
                printDefaultStatsTable(statsData)
            }
        }

        private func printDefaultStatsTable(_ statsData: [StatsSnapshot]) {
            let header = [["Container ID", "Cpu %", "Memory Usage", "Net Rx/Tx", "Block I/O", "Pids"]]
            var rows = header

            for snapshot in statsData {
                let stats1 = snapshot.stats1
                let stats2 = snapshot.stats2

                let cpuPercent = Self.calculateCPUPercent(
                    cpuUsageUsec1: stats1.cpuUsageUsec,
                    cpuUsageUsec2: stats2.cpuUsageUsec,
                    timeDeltaUsec: 2_000_000  // 2 seconds in microseconds
                )
                let cpuStr = String(format: "%.2f%%", cpuPercent)

                let memUsageStr = "\(Self.formatBytes(stats2.memoryUsageBytes)) / \(Self.formatBytes(stats2.memoryLimitBytes))"
                let netStr = "\(Self.formatBytes(stats2.networkRxBytes)) / \(Self.formatBytes(stats2.networkTxBytes))"
                let blockStr = "\(Self.formatBytes(stats2.blockReadBytes)) / \(Self.formatBytes(stats2.blockWriteBytes))"

                let pidsStr = "\(stats2.numProcesses)"

                rows.append([snapshot.container.id, cpuStr, memUsageStr, netStr, blockStr, pidsStr])
            }

            // Always print header, even if no containers
            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }

        private func printIOStatsTable(_ statsData: [StatsSnapshot]) {
            let header = [["CONTAINER", "READ/s", "WRITE/s", "LAT(ms)", "FSYNC(ms)", "QD", "DIRTY", "BACKEND"]]
            var rows = header

            for snapshot in statsData {
                let stats2 = snapshot.stats2

                // Calculate throughput from bytes (convert to MB/s)
                let readMBps = Self.formatThroughput(stats2.blockReadBytes)
                let writeMBps = Self.formatThroughput(stats2.blockWriteBytes)

                // Format latency metrics
                let latency = stats2.readLatencyMs != nil ? String(format: "%.1f", stats2.readLatencyMs!) : "N/A"
                let fsyncLatency = stats2.fsyncLatencyMs != nil ? String(format: "%.1f", stats2.fsyncLatencyMs!) : "N/A"

                // Format queue depth
                let queueDepth = stats2.queueDepth != nil ? "\(stats2.queueDepth!)" : "N/A"

                // Format dirty pages percentage
                let dirty = stats2.dirtyPagesPercent != nil ? String(format: "%.1f%%", stats2.dirtyPagesPercent!) : "N/A"

                // Storage backend
                let backend = stats2.storageBackend ?? "unknown"

                rows.append([
                    snapshot.container.id,
                    readMBps,
                    writeMBps,
                    latency,
                    fsyncLatency,
                    queueDepth,
                    dirty,
                    backend,
                ])
            }

            // Always print header, even if no containers
            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }

        static func formatThroughput(_ bytes: UInt64) -> String {
            let mb = 1024.0 * 1024.0
            let kb = 1024.0
            let value = Double(bytes)

            if value >= mb {
                return String(format: "%.0fMB", value / mb)
            } else if value >= kb {
                return String(format: "%.0fKB", value / kb)
            } else {
                return "\(bytes)B"
            }
        }

        private func clearScreen() {
            // Move cursor to home position and clear from cursor to end of screen
            print("\u{001B}[H\u{001B}[J", terminator: "")
            fflush(stdout)
        }
    }
}
