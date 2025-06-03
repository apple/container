//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import TerminalProgress

extension Application {
    struct ContainerStart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start a container")

        @Flag(name: .shortAndLong, help: "Attach STDOUT/STDERR")
        var attach = false

        @Flag(name: .shortAndLong, help: "Attach container's STDIN")
        var interactive = false

        // FIXME: Add in detach keys support.
        @OptionGroup(visibility: .hidden)
        var detachFlags: Flags.Detach

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Container's ID")
        var containerID: String

        func run() async throws {
            var exitCode: Int32 = 127

            let progressConfig = try ProgressConfig(
                description: "Starting container"
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            let container = try await ClientContainer.get(id: containerID)
            let process = try await container.bootstrap()

            progress.set(description: "Starting init process")
            let detach = !self.attach && !self.interactive
            do {
                let io = try ProcessIO.create(
                    tty: container.configuration.initProcess.terminal,
                    interactive: self.interactive,
                    detach: detach
                )
                progress.finish()
                if detach {
                    try await process.start(io.stdio)
                    defer {
                        try? io.close()
                    }
                    try io.closeAfterStart()
                    print(self.containerID)
                    return
                }

                exitCode = try await Application.handleProcess(io: io, process: process)
            } catch {
                try? await container.stop()

                if error is ContainerizationError {
                    throw error
                }
                throw ContainerizationError(.internalError, message: "failed to start container: \(error)")
            }
            throw ArgumentParser.ExitCode(exitCode)
        }
    }
}
