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
import MachineAPIClient
import TerminalProgress

extension Application {
    public struct MachineDelete: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a container machine",
            aliases: ["rm"]
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @OptionGroup(visibility: .hidden)
        var progressFlags: Flags.Progress

        @Argument(help: "Container machine ID")
        var id: String

        public func run() async throws {
            let client = MachineClient()

            let wasDefault = try await client.getDefault() == id

            let progressConfig = try self.progressFlags.makeConfig(
                description: "Deleting container machine"
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            try? await client.stop(id: id)
            try await client.delete(id: id)

            progress.finish()
            print(id)

            if wasDefault {
                log.info("Deleted default container '\(id)'. Set a new default with 'container machine set-default <id>'.")
            }
        }
    }
}
