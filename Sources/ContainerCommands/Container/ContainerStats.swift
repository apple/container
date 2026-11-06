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

            try Output.render(payload: statsData.map { StatsReport(snapshot: $0) }, format: format) {
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

        struct StatsSnapshot {
            let container: ContainerSnapshot
            let stats1: ContainerResource.ContainerStats
            let sampledAt1: ContinuousClock.Instant
            let stats2: ContainerResource.ContainerStats
            let sampledAt2: ContinuousClock.Instant

            /// Fraction of one core, matching `top` and `docker stats` once shown as a
            /// percentage: 4.0 is four cores saturated. Deliberately not divided by the
            /// container's CPU allocation. Nil when there is no second sample to compare.
            var cpuUtilization: Double? {
                guard let first = stats1.cpuUsageUsec, let second = stats2.cpuUsageUsec else {
                    return nil
                }
                let elapsed = sampledAt2 - sampledAt1
                guard elapsed > .zero else {
                    return nil
                }
                return ContainerStats.calculateCPUUtilization(
                    cpuUsage1: .microseconds(first),
                    cpuUsage2: .microseconds(second),
                    timeInterval: elapsed
                )
            }
        }

        static let sampleInterval: Duration = .seconds(2)

        /// The payload for the machine-readable formats: the second sample plus the CPU
        /// utilization derived from both.
        ///
        /// `cpuUtilization` is a fraction of one core (1.0 is one core fully used, 2.5 is
        /// two and a half cores). Formatting it, for example as a percentage, is left to
        /// the consumer; only the table output renders a percentage.
        ///
        /// `ContainerResource.ContainerStats` models a single sample, and a rate is not a
        /// property of one sample, so the derived value lives here rather than widening that
        /// type. The sample is wrapped and flattened on encode so the stored shape stays
        /// additive (`cpuUtilization` only) without copying every sample field onto this type.
        ///
        /// Encoding goes through one keyed container. TOMLEncoder replaces `encoder.value`
        /// on each `container(keyedBy:)` call, so `stats.encode(to:)` followed by a second
        /// container would drop the sample fields.
        struct StatsReport: Encodable {
            let stats: ContainerResource.ContainerStats
            let cpuUtilization: Double?

            init(snapshot: StatsSnapshot) {
                self.init(stats: snapshot.stats2, cpuUtilization: snapshot.cpuUtilization)
            }

            init(stats: ContainerResource.ContainerStats, cpuUtilization: Double?) {
                self.stats = stats
                self.cpuUtilization = cpuUtilization
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(stats.id, forKey: .id)
                try container.encodeIfPresent(stats.cpuUsageUsec, forKey: .cpuUsageUsec)
                try container.encodeIfPresent(stats.memoryUsageBytes, forKey: .memoryUsageBytes)
                try container.encodeIfPresent(stats.memoryLimitBytes, forKey: .memoryLimitBytes)
                try container.encodeIfPresent(stats.networkRxBytes, forKey: .networkRxBytes)
                try container.encodeIfPresent(stats.networkTxBytes, forKey: .networkTxBytes)
                try container.encodeIfPresent(stats.blockReadBytes, forKey: .blockReadBytes)
                try container.encodeIfPresent(stats.blockWriteBytes, forKey: .blockWriteBytes)
                try container.encodeIfPresent(stats.numProcesses, forKey: .numProcesses)
                try container.encodeIfPresent(cpuUtilization, forKey: .cpuUtilization)
            }

            private enum CodingKeys: String, CodingKey {
                case id
                case cpuUtilization
                case cpuUsageUsec
                case memoryUsageBytes
                case memoryLimitBytes
                case networkRxBytes
                case networkTxBytes
                case blockReadBytes
                case blockWriteBytes
                case numProcesses
            }
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
        ///   - cpuUsage1: CPU usage from the first sample
        ///   - cpuUsage2: CPU usage from the second sample
        ///   - timeInterval: Measured interval between the two samples
        /// - Returns: Fractional CPU utilization where 1.0 = one fully utilized core
        static func calculateCPUUtilization(
            cpuUsage1: Duration,
            cpuUsage2: Duration,
            timeInterval: Duration
        ) -> Double {
            let cpuDelta =
                cpuUsage2 > cpuUsage1
                ? cpuUsage2 - cpuUsage1
                : .seconds(0)
            return cpuDelta / timeInterval
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
                let stats2 = snapshot.stats2

                if let cpuUtilization = snapshot.cpuUtilization {
                    row.append(String(format: "%.2f%%", cpuUtilization * 100.0))
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
