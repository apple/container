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
import ContainerizationError
import MachineAPIClient
import TerminalProgress

extension Application {
    public struct MachineStop: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop a running container machine"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @OptionGroup(visibility: .hidden)
        var progressFlags: Flags.Progress

        @Argument(help: "container machine ID (uses default if not specified)")
        var id: String?

        public func run() async throws {
            let client = MachineClient()

            let machineId = try await resolveMachineId(id, client: client)

            let progressConfig = try self.progressFlags.makeConfig(
                description: "Stopping container machine"
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            try await client.stop(id: machineId)

            progress.finish()
            print(machineId)
        }
    }
}
