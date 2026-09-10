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

import ArgumentParser
import ContainerAPIClient
import Foundation

extension Application {
    public struct SystemPrune: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove stopped containers, unused networks, dangling images, and unused volumes"
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Remove all unused images, not just dangling ones")
        var all: Bool = false

        @Flag(name: .long, help: "Also remove volumes not used by any container")
        var volumes: Bool = false

        @Flag(name: .shortAndLong, help: "Do not prompt for confirmation")
        var force: Bool = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        /// A machine-readable summary of everything removed by a system prune.
        struct Report: Codable {
            var deletedContainers: [String]
            var deletedNetworks: [String]
            var deletedImages: [String]
            var deletedImageDigests: [String]
            var deletedVolumes: [String]
            var reclaimedBytes: UInt64
        }

        public func run() async throws {
            guard force || confirm() else {
                return
            }

            // Prune in dependency order: removing stopped containers first frees the
            // images, volumes, and networks they referenced so those can be reclaimed too.
            let containerResult = try await ContainerClient().prune()
            let networkResult = try await NetworkClient().prune()
            let imageResult = try await ClientImage.prune(all: all)
            let volumeResult = volumes ? try await ClientVolume.prune() : nil

            log(failures: containerResult.failed, kind: "container")
            log(failures: networkResult.failed, kind: "network")
            log(failures: imageResult.failed, kind: "image")
            if let volumeResult {
                log(failures: volumeResult.failed, kind: "volume")
            }

            let report = Report(
                deletedContainers: containerResult.pruned,
                deletedNetworks: networkResult.pruned,
                deletedImages: imageResult.pruned,
                deletedImageDigests: imageResult.deletedDigests,
                deletedVolumes: volumeResult?.pruned ?? [],
                reclaimedBytes: containerResult.reclaimedBytes + imageResult.reclaimedBytes
                    + (volumeResult?.reclaimedBytes ?? 0)
            )

            try Output.render(payload: report, format: format, jsonOptions: .pretty) {
                pruneSummary(report)
            }
        }

        /// Prompt the user before performing the destructive prune. Defaults to "no".
        private func confirm() -> Bool {
            print("WARNING! This will remove:")
            print("  - all stopped containers")
            print("  - all networks not used by at least one container")
            if all {
                print("  - all images without at least one container associated to them")
            } else {
                print("  - all dangling images")
            }
            if volumes {
                print("  - all volumes not used by at least one container")
            }
            print("Are you sure you want to continue? [y/N] ", terminator: "")

            guard let answer = readLine(strippingNewline: true)?.lowercased() else {
                return false
            }
            return answer == "y" || answer == "yes"
        }

        private func log(failures: [PruneResult.Failure], kind: String) {
            for failure in failures {
                log.error(
                    "failed to prune \(kind)",
                    metadata: [
                        "id": "\(failure.id)",
                        "error": "\(failure.error)",
                    ])
            }
        }

        private func pruneSummary(_ report: Report) -> String {
            var sections = [String]()

            func section(_ title: String, _ lines: [String]) {
                guard !lines.isEmpty else { return }
                sections.append(([title] + lines).joined(separator: "\n"))
            }

            section("Deleted Containers:", report.deletedContainers)
            section("Deleted Networks:", report.deletedNetworks)
            section(
                "Deleted Images:",
                report.deletedImages.map { "untagged \($0)" }
                    + report.deletedImageDigests.map { "deleted \($0)" })
            section("Deleted Volumes:", report.deletedVolumes)

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let freed = formatter.string(fromByteCount: Int64(report.reclaimedBytes))
            sections.append("Total reclaimed space: \(freed)")

            return sections.joined(separator: "\n\n")
        }
    }
}
