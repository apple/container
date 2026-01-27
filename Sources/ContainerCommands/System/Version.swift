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
import ContainerVersion
import Foundation

extension Application {
    public struct SystemVersion: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Show version information"
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let cliInfo = VersionInfo(
                version: ReleaseVersion.version(),
                buildType: ReleaseVersion.buildType(),
                commit: ReleaseVersion.gitCommit() ?? "unspecified",
                appName: "container"
            )

            // Try to get API server version info
            let serverInfo: VersionInfo?
            do {
                let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
                serverInfo = VersionInfo(
                    version: health.apiServerVersion,
                    buildType: health.apiServerBuild,
                    commit: health.apiServerCommit,
                    appName: health.apiServerAppName
                )
            } catch {
                serverInfo = nil
            }

            let versions = [cliInfo, serverInfo].compactMap { $0 }

            switch format {
            case .table:
                printVersionTable(versions: versions)
            case .json:
                try printVersionJSON(versions: versions)
            }
        }

        private func printVersionTable(versions: [VersionInfo]) {
            let header = ["COMPONENT", "VERSION", "BUILD", "COMMIT"]
            let rows = [header] + versions.map { [$0.appName, $0.version, $0.buildType, $0.commit] }

            let table = TableOutput(rows: rows)
            print(table.format())
        }

        private func printVersionJSON(versions: [VersionInfo]) throws {
            let data = try JSONEncoder().encode(versions)
            print(String(data: data, encoding: .utf8) ?? "[]")
        }
    }

    public struct VersionInfo: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
    }
}
