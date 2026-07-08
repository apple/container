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
                // Static mode - get stats once and exit.
                try await runStatic()
            } else {
                // Streaming mode - continuously update like top.
                let client = ContainerClient()
                let containerIds = containers

                // Validate specified containers exist before entering the
                // alternate screen buffer, so the error is visible.
                if !containerIds.isEmpty {
                    let specified = try await client.list(filters: ContainerListFilters(ids: containerIds))
                    try Self.validate(requested: containerIds, found: specified)
                }

                try await StatsRendering.stream(idHeader: "Container ID") { [client, containerIds] in
                    let containersToShow: [ContainerSnapshot]
                    if containerIds.isEmpty {
                        containersToShow = try await client.list(filters: ContainerListFilters(status: .running))
                    } else {
                        containersToShow = try await client.list(filters: ContainerListFilters(ids: containerIds))
                    }
                    let runningIds = containersToShow.filter { $0.status == .running }.map { $0.id }
                    return try await StatsRendering.collect(client: client, ids: runningIds)
                }
            }
        }

        private func runStatic() async throws {
            let client = ContainerClient()

            let containersToShow: [ContainerSnapshot]
            if containers.isEmpty {
                // No containers specified - show all running containers.
                containersToShow = try await client.list(filters: ContainerListFilters(status: .running))
            } else {
                // Fetch specified containers by ID and validate they were all found.
                containersToShow = try await client.list(filters: ContainerListFilters(ids: containers))
                try Self.validate(requested: containers, found: containersToShow)
            }

            let runningIds = containersToShow.filter { $0.status == .running }.map { $0.id }
            let rows = try await StatsRendering.collect(client: client, ids: runningIds)
            try StatsRendering.renderStatic(rows: rows, format: format, idHeader: "Container ID")
        }

        /// Throws `.notFound` if any requested container id is missing from `found`.
        private static func validate(requested: [String], found: [ContainerSnapshot]) throws {
            for containerId in requested {
                guard found.contains(where: { $0.id == containerId }) else {
                    throw ContainerizationError(
                        .notFound,
                        message: "no such container: \(containerId)"
                    )
                }
            }
        }
    }
}
