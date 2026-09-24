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
import ContainerizationOS
import Foundation
import MachineAPIClient

extension Application {
    public struct MachineLogs: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Fetch container machine logs"
        )

        @Flag(name: .long, help: "Display the boot log for the container machine instead of stdio")
        var boot: Bool = false

        @Flag(name: .shortAndLong, help: "Follow log output")
        var follow: Bool = false

        @Option(name: .short, help: "Number of lines to show from the end of the logs. If not provided this will print all of the logs")
        var numLines: Int?

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Machine VM ID (uses default if not specified)")
        var id: String?

        public func run() async throws {
            let sigHandler = AsyncSignalHandler.create(notify: [SIGINT, SIGTERM])

            Task {
                for await _ in sigHandler.signals {
                    Darwin.exit(0)
                }
            }

            let client = MachineClient()
            let id = try await resolveMachineId(id, client: client)

            let fhs = try await client.logs(id: id)
            let fileHandle = boot ? fhs[1] : fhs[0]

            try await LogTailer.tail(
                fh: fileHandle,
                n: numLines,
                follow: follow
            )
        }
    }
}
