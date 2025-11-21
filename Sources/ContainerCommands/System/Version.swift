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
import ContainerVersion
import Foundation

extension Application {
    public struct VersionCommand: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Show version information"
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            let cliInfo = VersionInfo(
                version: ReleaseVersion.version(),
                buildType: ReleaseVersion.buildType(),
                commit: ReleaseVersion.gitCommit() ?? "unspecified",
                appName: "container CLI"
            )

            // Try to get API server version info
            let serverInfo: VersionInfo?
            do {
                let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
                serverInfo = VersionInfo(
                    version: health.apiServerVersion,
                    buildType: health.apiServerBuild ?? "unknown",
                    commit: health.apiServerCommit,
                    appName: "container API Server"
                )
            } catch {
                serverInfo = nil
            }

            switch format {
            case .table:
                printVersionTable(cli: cliInfo, server: serverInfo)
            case .json:
                try printVersionJSON(cli: cliInfo, server: serverInfo)
            }
        }


        private func printVersionTable(cli: VersionInfo, server: VersionInfo?) {
            var rows: [[String]] = [
                ["COMPONENT", "VERSION", "BUILD", "COMMIT"],
                ["CLI", cli.version, cli.buildType, cli.commit]
            ]
            
            if let server = server {
                rows.append(["API Server", server.version, server.buildType, server.commit])
            }
            
            let table = TableOutput(rows: rows)
            print(table.format())
        }

        private func printVersionJSON(cli: VersionInfo, server: VersionInfo?) throws {
            let output = VersionJSON(
                version: cli.version,
                buildType: cli.buildType,
                commit: cli.commit,
                appName: cli.appName,
                server: server
            )
            let data = try JSONEncoder().encode(output)
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    public struct VersionInfo: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
    }

    struct VersionJSON: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
        let server: VersionInfo?
    }
}
