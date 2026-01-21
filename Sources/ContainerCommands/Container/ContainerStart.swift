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
import ContainerizationError
import ContainerizationOS
import Foundation
import TerminalProgress

extension Application {
    public struct ContainerStart: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start a container")

        @Flag(name: .shortAndLong, help: "Attach stdout/stderr")
        var attach = false

        @Flag(name: .shortAndLong, help: "Attach stdin")
        var interactive = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        public func run() async throws {
            var exitCode: Int32 = 127

            let progressConfig = try ProgressConfig(
                description: "Starting container"
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            let detach = !self.attach && !self.interactive
            let container = try await ClientContainer.get(id: containerId)

            // Bootstrap and process start are both idempotent and don't fail the second time
            // around, however not doing an rpc is always faster :). The other bit is we don't
            // support attach currently, so we can't do `start -a` a second time and have it succeed.
            if container.status == .running {
                if !detach {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "attach is currently unsupported on already running containers"
                    )
                }
                print(containerId)
                return
            }

            for mount in container.configuration.mounts where mount.isVirtiofs {
                if !FileManager.default.fileExists(atPath: mount.source) {
                    throw ContainerizationError(.invalidState, message: "path '\(mount.source)' is not a directory")
                }
            }

            do {
                let io = try ProcessIO.create(
                    tty: container.configuration.initProcess.terminal,
                    interactive: self.interactive,
                    detach: detach
                )
                defer {
                    try? io.close()
                }

                let process = try await container.bootstrap(stdio: io.stdio)
                progress.finish()

                if detach {
                    try await process.start()
                    try io.closeAfterStart()
                    print(self.containerId)
                    return
                }

                exitCode = try await io.handleProcess(process: process, log: log)
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
