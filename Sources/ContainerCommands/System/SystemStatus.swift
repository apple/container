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
        }

        public func run() async throws {
            let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: "\(prefix)apiserver")
            if !isRegistered {
                if format == .json {
                    let status = PrintableStatus(
                        status: "unregistered",
                        appRoot: "",
                        installRoot: "",
                        logRoot: nil,
                        apiServerVersion: "",
                        apiServerCommit: "",
                        apiServerBuild: "",
                        apiServerAppName: ""
                    )
                    let data = try JSONEncoder().encode(status)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print("apiserver is not running and not registered with launchd")
                }
                Application.exit(withError: ExitCode(1))
            }

            // Now ping our friendly daemon. Fail after 10 seconds with no response.
            do {
                let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))

                if format == .json {
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
                    let data = try JSONEncoder().encode(status)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    let rows: [[String]] = [
                        ["FIELD", "VALUE"],
                        ["status", "running"],
                        ["appRoot", systemHealth.appRoot.path(percentEncoded: false)],
                        ["installRoot", systemHealth.installRoot.path(percentEncoded: false)],
                        ["logRoot", systemHealth.logRoot?.string ?? ""],
                        ["apiserver.version", systemHealth.apiServerVersion],
                        ["apiserver.commit", systemHealth.apiServerCommit],
                        ["apiserver.build", systemHealth.apiServerBuild],
                        ["apiserver.appName", systemHealth.apiServerAppName],
                    ]
                    let formatter = TableOutput(rows: rows)
                    print(formatter.format())
                }
            } catch {
                if format == .json {
                    let status = PrintableStatus(
                        status: "not running",
                        appRoot: "",
                        installRoot: "",
                        logRoot: nil,
                        apiServerVersion: "",
                        apiServerCommit: "",
                        apiServerBuild: "",
                        apiServerAppName: ""
                    )
                    let data = try JSONEncoder().encode(status)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print("apiserver is not running")
                }
                Application.exit(withError: ExitCode(1))
            }
        }
    }
}
