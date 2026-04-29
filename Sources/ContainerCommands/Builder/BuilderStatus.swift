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
                let client = ContainerClient()
                let container = try await client.get(id: "buildkit")

                if format == .json {
                    try Output.emit(Output.renderJSON([PrintableContainer(container)]))
                    return
                }

                if quiet && container.status != .running {
                    return
                }

                Output.emit(Output.renderList([PrintableBuilder(container)], quiet: quiet))
            } catch {
                if let czError = error as? ContainerizationError, czError.code == .notFound {
                    if !quiet {
                        print("builder is not running")
                        return
                    }
                }
                throw error
            }
        }
    }
}

private struct PrintableBuilder: ListDisplayable {
    let snapshot: ContainerSnapshot

    init(_ snapshot: ContainerSnapshot) {
        self.snapshot = snapshot
    }

    static var tableHeader: [String] {
        ["ID", "IMAGE", "STATE", "ADDR", "CPUS", "MEMORY"]
    }

    var tableRow: [String] {
        [
            snapshot.id,
            snapshot.configuration.image.reference,
            snapshot.status.rawValue,
            snapshot.networks.map { $0.ipv4Address.description }.joined(separator: ","),
            "\(snapshot.configuration.resources.cpus)",
            "\(snapshot.configuration.resources.memoryInBytes / (1024 * 1024)) MB",
        ]
    }

    var quietValue: String {
        snapshot.id
    }
}
