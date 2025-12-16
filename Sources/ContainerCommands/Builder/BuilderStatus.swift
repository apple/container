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
    public struct BuilderStatus: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "status"
            config.abstract = "Display the builder container status"
            return config
        }

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the container ID")
        var quiet = false

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            do {
                let snapshot = try await ClientContainer.get(id: "buildkit")
                try printContainers(snapshots: [snapshot], format: format)
            } catch {
                if error is ContainerizationError {
                    if (error as? ContainerizationError)?.code == .notFound && !quiet {
                        print("builder is not running")
                        return
                    }
                }
                throw error
            }
        }

        private func createHeader() -> [[String]] {
            [["ID", "IMAGE", "STATE", "ADDR", "CPUS", "MEMORY"]]
        }

        private func printContainers(snapshots: [ContainerSnapshot], format: ListFormat) throws {
            if format == .json {
                let printables = snapshots.map {
                    PrintableContainer($0)
                }
                let data = try JSONEncoder().encode(printables)
                print(String(data: data, encoding: .utf8)!)

                return
            }

            if self.quiet {
                snapshots
                    .filter { $0.status == .running }
                    .forEach { print($0.configuration.id) }
                return
            }

            var rows = createHeader()
            for snapshot in snapshots {
                rows.append(snapshot.asRow)
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }
    }
}

extension ContainerSnapshot {
    fileprivate var asRow: [String] {
        [
            self.configuration.id,
            self.configuration.image.reference,
            self.status.rawValue,
            self.networks.compactMap { try? CIDRAddress($0.address).address.description }.joined(separator: ","),
            "\(self.configuration.resources.cpus)",
            "\(self.configuration.resources.memoryInBytes / (1024 * 1024)) MB",
        ]
    }
}
