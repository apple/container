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
import ContainerizationError
import Foundation

extension Application {
    public struct SystemDF: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "df",
            abstract: "Show disk usage for images, containers, and volumes"
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            let stats = try await ClientDiskUsage.get()

            if format == .json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(stats)
                guard let jsonString = String(data: data, encoding: .utf8) else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to encode JSON output"
                    )
                }
                print(jsonString)
                return
            }

            printTable(stats: stats)
        }

        private func printTable(stats: DiskUsageStats) {
            var rows: [[String]] = []

            // Header row
            rows.append(["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"])

            // Images row
            rows.append([
                "Images",
                "\(stats.images.total)",
                "\(stats.images.active)",
                formatSize(stats.images.sizeInBytes),
                formatReclaimable(stats.images.reclaimable, total: stats.images.sizeInBytes),
            ])

            // Containers row
            rows.append([
                "Containers",
                "\(stats.containers.total)",
                "\(stats.containers.active)",
                formatSize(stats.containers.sizeInBytes),
                formatReclaimable(stats.containers.reclaimable, total: stats.containers.sizeInBytes),
            ])

            // Volumes row
            rows.append([
                "Local Volumes",
                "\(stats.volumes.total)",
                "\(stats.volumes.active)",
                formatSize(stats.volumes.sizeInBytes),
                formatReclaimable(stats.volumes.reclaimable, total: stats.volumes.sizeInBytes),
            ])

            let tableFormatter = TableOutput(rows: rows)
            print(tableFormatter.format())
        }

        private func formatSize(_ bytes: UInt64) -> String {
            if bytes == 0 {
                return "0 B"
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(bytes))
        }

        private func formatReclaimable(_ reclaimable: UInt64, total: UInt64) -> String {
            let sizeStr = formatSize(reclaimable)

            if total == 0 {
                return "\(sizeStr) (0%)"
            }

            // Cap at 100% in case reclaimable > total (shouldn't happen but be defensive)
            let percentage = min(100, Int(round(Double(reclaimable) / Double(total) * 100.0)))
            return "\(sizeStr) (\(percentage)%)"
        }
    }
}
