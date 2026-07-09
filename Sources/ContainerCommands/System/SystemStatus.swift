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
import ContainerPlugin
import ContainerizationError
import Foundation
import Logging

extension Application {
    public struct SystemStatus: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the status of `container` services"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for services")
        var prefix: String = "com.apple.container."

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        struct PrintableStatus: Codable {
            let status: String
            let appRoot: String
            let installRoot: String
            let logRoot: String?
            let apiServerVersion: String
            let apiServerCommit: String
            let apiServerBuild: String
            let apiServerAppName: String

            init(
                status: String,
                appRoot: String = "",
                installRoot: String = "",
                logRoot: String? = nil,
                apiServerVersion: String = "",
                apiServerCommit: String = "",
                apiServerBuild: String = "",
                apiServerAppName: String = ""
            ) {
                self.status = status
                self.appRoot = appRoot
                self.installRoot = installRoot
                self.logRoot = logRoot
                self.apiServerVersion = apiServerVersion
                self.apiServerCommit = apiServerCommit
                self.apiServerBuild = apiServerBuild
                self.apiServerAppName = apiServerAppName
            }
        }

        public func run() async throws {
            let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: "\(prefix)apiserver")
            if !isRegistered {
                try Output.render(payload: PrintableStatus(status: "unregistered"), format: format) {
                    "apiserver is not running and not registered with launchd"
                }
                Application.exit(withError: ExitCode(1))
            }

            // Now ping our friendly daemon. Fail after 10 seconds with no response.
            do {
                let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
                let status = PrintableStatus(
                    status: "running",
                    appRoot: systemHealth.appRoot.path(percentEncoded: false),
                    installRoot: systemHealth.installRoot.path(percentEncoded: false),
                    logRoot: systemHealth.logRoot?.string,
                    apiServerVersion: systemHealth.apiServerVersion,
                    apiServerCommit: systemHealth.apiServerCommit,
                    apiServerBuild: systemHealth.apiServerBuild,
                    apiServerAppName: systemHealth.apiServerAppName
                )
                try Output.render(payload: status, format: format) {
                    Self.statusTable(status)
                }
            } catch {
                try Output.render(payload: PrintableStatus(status: "not running"), format: format) {
                    "apiserver is not running"
                }
                Application.exit(withError: ExitCode(1))
            }
        }

        private static func statusTable(_ status: PrintableStatus) -> String {
            let rows: [[String]] = [
                ["FIELD", "VALUE"],
                ["status", status.status],
                ["appRoot", status.appRoot],
                ["installRoot", status.installRoot],
                ["logRoot", status.logRoot ?? ""],
                ["apiserver.version", status.apiServerVersion],
                ["apiserver.commit", status.apiServerCommit],
                ["apiserver.build", status.apiServerBuild],
                ["apiserver.appName", status.apiServerAppName],
            ]
            return TableOutput(rows: rows).format()
        }
    }
}
