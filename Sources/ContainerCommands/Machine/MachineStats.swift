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
import ContainerResource
import ContainerizationError
import MachineAPIClient

extension Application {
    public struct MachineStats: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "stats",
            abstract: "Display resource usage statistics for a container machine")

        @Argument(help: "Container machine ID (uses default if not specified)")
        var id: String?

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .long, help: "Disable streaming stats and only pull the first result")
        var noStream = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let machineClient = MachineClient()
            let machineId = try await resolveMachineId(id, client: machineClient)

            // A running container machine is itself backed by a container, so its
            // resource usage is that container's stats. Resolve the backing
            // container id up front, which also errors on a stopped or missing
            // machine before any streaming UI is shown.
            let snapshot = try await machineClient.inspect(id: machineId)
            guard snapshot.status == .running else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine \(machineId) is not running"
                )
            }
            guard let containerId = snapshot.containerId else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine \(machineId) is running but has no container ID"
                )
            }

            let containerClient = ContainerClient()
            let idHeader = "Machine ID"

            if format != .table || noStream {
                // Static mode - get stats once and exit.
                let rows = try await Self.collect(
                    client: containerClient, containerId: containerId, machineId: machineId)
                try StatsRendering.renderStatic(rows: rows, format: format, idHeader: idHeader)
            } else {
                // Streaming mode - continuously update like top.
                try await StatsRendering.stream(idHeader: idHeader) { [containerClient, containerId, machineId] in
                    try await Self.collect(
                        client: containerClient, containerId: containerId, machineId: machineId)
                }
            }
        }

        /// Samples the machine's backing container, labeling the resulting row
        /// with the machine id rather than the internal container id.
        private static func collect(
            client: ContainerClient, containerId: String, machineId: String
        ) async throws -> [StatsRendering.Row] {
            try await StatsRendering.collect(client: client, ids: [containerId])
                .map { StatsRendering.Row(id: machineId, stats1: $0.stats1, stats2: $0.stats2) }
        }
    }
}
