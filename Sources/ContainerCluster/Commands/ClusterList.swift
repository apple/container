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
import ContainerClusterServiceClient
import ContainerLog
import ContainerResource
import Logging

// `ListFormat` lives in `ContainerResource`, which doesn't depend on ArgumentParser.
// ArgumentParser provides a free `init?(argument:)` for `RawRepresentable where RawValue == String`.
extension ListFormat: ExpressibleByArgument {}

public struct ClusterList: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List clusters",
        aliases: ["ls"]
    )

    @Flag(name: .long, help: "Show information about the nodes on clusters")
    var nodes = false

    @Option(name: .long, help: "Format of the output")
    var format: ListFormat = .table

    @Flag(name: .shortAndLong, help: "Only output the cluster name (the node name with --nodes)")
    var quiet = false

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }

        let clusters = try await ClusterClient().list()

        // `--nodes` only changes the table view. JSON, YAML and TOML always print the full cluster payload.
        let showNodeTable = nodes && format == .table
        let nodeRows = showNodeTable ? try await makeNodeRows(for: clusters) : []

        try Output.render(payload: clusters, format: format) {
            if showNodeTable {
                return renderTableOrNames(nodeRows)
            }
            return renderTableOrNames(clusters)
        }
    }

    /// Builds one row per node. The cluster service does not report CPU and memory,
    /// so those columns come from the nodes' live containers.
    private func makeNodeRows(for clusters: [ClusterResource]) async throws -> [ClusterNodeRow] {
        let filters = ContainerListFilters().withPlugin(ClusterHelper.pluginName)
        let containers = try await ContainerClient().list(filters: filters)
        return ClusterHelper.buildNodeRows(infos: clusters, snapshots: containers)
    }

    /// With `--quiet`, one name per line. Otherwise a table with a header row.
    private func renderTableOrNames<T: ListDisplayable>(_ items: [T]) -> String {
        if quiet {
            return items.map(\.quietValue).joined(separator: "\n")
        }
        return ClusterHelper.renderTable(items)
    }
}
