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
import ContainerizationOS
import Foundation

extension Application {
    public struct ContainerStats: AsyncLoggableCommand {
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
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            if format != .table || noStream {
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

                let containerIds = containers
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { group.cancelAll() }
                    group.addTask {
                        let handler = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM])
                        for await _ in handler.signals {
                            throw CancellationError()
                        }
                    }
                    group.addTask { [containerIds] in
                        try await Self.runStreaming(containerIds: containerIds)
                    }
                    do {
                        try await group.next()
                    } catch is CancellationError {
                        // Normal exit on signal, defer will restore the terminal
                    }
                }
            }
        }

        private func runStatic() async throws {
            let client = ContainerClient()

            let containersToShow: [ContainerSnapshot]
            if containers.isEmpty {
                // No containers specified - show all running containers
                containersToShow = try await client.list(filters: ContainerListFilters(status: .running))
            } else {
                // Fetch specified containers by ID
                containersToShow = try await client.list(filters: ContainerListFilters(ids: containers))
                // Validate all specified containers were found
                for containerId in containers {
                    guard containersToShow.contains(where: { $0.id == containerId }) else {
                        throw ContainerizationError(
                            .notFound,
                            message: "no such container: \(containerId)"
                        )
                    }
                }
            }

            let statsData = try await Self.collectStats(client: client, for: containersToShow)

            try Output.render(payload: statsData.map { $0.stats2 }, format: format) {
                Self.statsTable(statsData)
            }
        }

        private static func runStreaming(containerIds: [String]) async throws {
            let client = ContainerClient()

            // If containers were specified, validate they all exist upfront
            if !containerIds.isEmpty {
                let specifiedContainers = try await client.list(filters: ContainerListFilters(ids: containerIds))
                for containerId in containerIds {
                    guard specifiedContainers.contains(where: { $0.id == containerId }) else {
                        throw ContainerizationError(
                            .notFound,
                            message: "no such container: \(containerId)"
                        )
                    }
                }
            }

            clearScreen()
            // Show header right away.
            print(statsTable([]))

            while true {
                do {
                    let containersToShow: [ContainerSnapshot]
                    if containerIds.isEmpty {
                        containersToShow = try await client.list(filters: ContainerListFilters(status: .running))
                    } else {
                        containersToShow = try await client.list(filters: ContainerListFilters(ids: containerIds))
                    }

                    let statsData = try await collectStats(client: client, for: containersToShow)

                    // Clear screen and reprint
                    clearScreen()
                    print(statsTable(statsData))

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
            let container: ContainerSnapshot
            let stats1: ContainerResource.ContainerStats
            let stats2: ContainerResource.ContainerStats
        }

        private static func collectStats(client: ContainerClient, for containers: [ContainerSnapshot]) async throws -> [StatsSnapshot] {
            let running = containers.filter { $0.status == .running }

            // First sample. Containers that error out are skipped.
            let firstSample = await sample(client: client, ids: running.map { $0.id })
            var snapshots = running.compactMap { container -> StatsSnapshot? in
                guard let stats = firstSample[container.id] else {
                    return nil
                }
                return StatsSnapshot(container: container, stats1: stats, stats2: stats)
            }

            guard !snapshots.isEmpty else {
                return snapshots
            }

            // Wait 2 seconds for CPU delta calculation
            try await Task.sleep(for: .seconds(2))

            // Second sample
            let secondSample = await sample(client: client, ids: snapshots.map { $0.container.id })
            snapshots = snapshots.map { snapshot -> StatsSnapshot in
                guard let stats2 = secondSample[snapshot.container.id] else {
                    // Keep the original stats if second sample fails
                    return snapshot
                }
                return StatsSnapshot(container: snapshot.container, stats1: snapshot.stats1, stats2: stats2)
            }

            return snapshots
        }

        /// Fetch stats for every container concurrently, omitting the ones whose
        /// stats could not be read. One round trip per container in series adds
        /// up quickly once more than a handful of containers are running.
        private static func sample(client: ContainerClient, ids: [String]) async -> [String: ContainerResource.ContainerStats] {
            await withTaskGroup(
                of: (String, ContainerResource.ContainerStats?).self,
                returning: [String: ContainerResource.ContainerStats].self
            ) { group in
                for id in ids {
                    group.addTask {
                        (id, try? await client.stats(id: id))
                    }
                }

                var results = [String: ContainerResource.ContainerStats]()
                for await (id, stats) in group {
                    results[id] = stats
                }
                return results
            }
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

        private static func statsTable(_ statsData: [StatsSnapshot]) -> String {
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
            return TableOutput(rows: rows).format()
        }

        private static func clearScreen() {
            // Move cursor to home position and clear from cursor to end of screen
            print("\u{001B}[H\u{001B}[J", terminator: "")
            fflush(stdout)
        }
    }
}
