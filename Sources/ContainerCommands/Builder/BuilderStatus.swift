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
import ContainerizationExtras
import Foundation

extension Application {
    public struct BuilderStatus: AsyncLoggableCommand {
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
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            do {
                let container = try await ClientContainer.get(id: "buildkit")
                try printContainers(containers: [container], format: format)
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

        private func printContainers(containers: [ClientContainer], format: ListFormat) throws {
            if format == .json {
                let printables = containers.map {
                    PrintableContainer($0)
                }
                let data = try JSONEncoder().encode(printables)
                print(String(data: data, encoding: .utf8)!)

                return
            }

            if self.quiet {
                containers
                    .filter { $0.status == .running }
                    .forEach { print($0.id) }
                return
            }

            var rows = createHeader()
            for container in containers {
                rows.append(container.asRow)
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }
    }
}

extension ClientContainer {
    fileprivate var asRow: [String] {
        [
            self.id,
            self.configuration.image.reference,
            self.status.rawValue,
            self.networks.compactMap { $0.ipv4Address.description }.joined(separator: ","),
            "\(self.configuration.resources.cpus)",
            "\(self.configuration.resources.memoryInBytes / (1024 * 1024)) MB",
        ]
    }
}
