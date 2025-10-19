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
import ContainerizationError
import ContainerizationOS
import Foundation
import OSLog

extension Application {
    public struct SystemLogs: AsyncParsableCommand {
        public static let subsystem = "com.apple.container"

        public static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Fetch system logs for `container` services"
        )

        @Flag(name: .shortAndLong, help: "Follow log output")
        var follow: Bool = false

        @Option(
            name: .long,
            help: "Fetch logs starting from the specified time period (minus the current time); supported formats: m, h, d"
        )
        var last: String = "5m"

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            let process = Process()
            let sigHandler = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM])

            Task {
                for await _ in sigHandler.signals {
                    process.terminate()
                    Darwin.exit(0)
                }
            }

            do {
                var args = ["log"]
                args.append(self.follow ? "stream" : "show")
                args.append(contentsOf: ["--info", "--debug"])
                if !self.follow {
                    args.append(contentsOf: ["--last", last])
                }
                args.append(contentsOf: ["--predicate", "subsystem = 'com.apple.container'"])

                process.launchPath = "/usr/bin/env"
                process.arguments = args

                process.standardOutput = FileHandle.standardOutput
                process.standardError = FileHandle.standardError

                try process.run()
                process.waitUntilExit()
            } catch {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "failed to system logs: \(error)"
                )
            }
            throw ArgumentParser.ExitCode(process.terminationStatus)
        }
    }
}
