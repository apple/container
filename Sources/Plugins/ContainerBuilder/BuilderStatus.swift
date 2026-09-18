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
import ContainerLog
import ContainerResource
import ContainerizationError
import Foundation
import Logging

struct BuilderStatus: AsyncParsableCommand {
    public static var configuration: CommandConfiguration {
        var config = CommandConfiguration()
        config.commandName = "status"
        config.abstract = "Display the builder container status"
        return config
    }

    // NOTE: The `ContainerCommands` version of this command supported `--format
    // json|yaml|toml|table` and `--quiet`, backed by `Output`/`ListFormat`/`ListDisplayable`
    // (Sources/ContainerCommands/OutputRendering.swift). Those types live in the
    // `ContainerCommands` monolith, not a shared library, so pulling them in here would
    // mean either depending on the whole `ContainerCommands` target or duplicating that
    // rendering system. Dropped instead: this always prints a plain table.

    @OptionGroup
    public var logOptions: Flags.Logging

    public init() {}

    var log: Logger {
        var logger = Logger(label: "container", factory: { _ in StderrLogHandler() })
        logger.logLevel = logOptions.debug ? .debug : .info
        return logger
    }

    public func run() async throws {
        do {
            let client = ContainerClient()
            let container = try await client.get(id: "buildkit")
            print(Self.table(for: container))
        } catch let error as ContainerizationError where error.code == .notFound {
            print("builder is not running")
        }
    }

    private static func table(for snapshot: ContainerSnapshot) -> String {
        let header = ["ID", "IMAGE", "STATE", "IP", "CPUS", "MEMORY"]
        let row = [
            snapshot.id,
            snapshot.configuration.image.reference,
            snapshot.status.rawValue,
            snapshot.networks.map { $0.ipv4Address.description }.joined(separator: ","),
            "\(snapshot.configuration.resources.cpus)",
            "\(snapshot.configuration.resources.memoryInBytes / (1024 * 1024)) MB",
        ]
        let widths = header.indices.map { max(header[$0].count, row[$0].count) }
        func formatted(_ columns: [String]) -> String {
            columns.indices.map { columns[$0].padding(toLength: widths[$0] + 2, withPad: " ", startingAt: 0) }.joined()
        }
        return "\(formatted(header))\n\(formatted(row))"
    }
}
