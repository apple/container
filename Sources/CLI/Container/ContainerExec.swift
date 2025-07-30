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
import Foundation

extension Application {
    struct ContainerExec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "exec",
            abstract: "Run a new command in a running container")

        @OptionGroup
        var processFlags: Flags.Process

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Running containers ID")
        var containerID: String

        @Argument(parsing: .captureForPassthrough, help: "New process arguments")
        var arguments: [String]

        func run() async throws {
            var exitCode: Int32 = 127
            let container = try await ClientContainer.get(id: containerID)
            try ensureRunning(container: container)

            let stdin = self.processFlags.interactive
            let tty = self.processFlags.tty

            var config = container.configuration.initProcess
            config.executable = arguments.first!
            config.arguments = [String](self.arguments.dropFirst())
            config.terminal = tty
            config.environment.append(
                contentsOf: try Parser.allEnv(
                    imageEnvs: [],
                    envFiles: self.processFlags.envFile,
                    envs: self.processFlags.env
                ))

            if let cwd = self.processFlags.cwd {
                config.workingDirectory = cwd
            }

            let defaultUser = config.user
            let (user, additionalGroups) = Parser.user(
                user: processFlags.user, uid: processFlags.uid,
                gid: processFlags.gid, defaultUser: defaultUser)
            config.user = user
            config.supplementalGroups.append(contentsOf: additionalGroups)

            do {
                let io = try ProcessIO.create(tty: tty, interactive: stdin, detach: false)

                if !self.processFlags.tty {
                    var handler = SignalThreshold(threshold: 3, signals: [SIGINT, SIGTERM])
                    handler.start {
                        print("Received 3 SIGINT/SIGTERM's, forcefully exiting.")
                        Darwin.exit(1)
                    }
                }

                let process = try await container.createProcess(
                    id: UUID().uuidString.lowercased(),
                    configuration: config,
                    stdio: io.stdio
                )

                exitCode = try await Application.handleProcess(io: io, process: process)
            } catch {
                if error is ContainerizationError {
                    throw error
                }
                throw ContainerizationError(.internalError, message: "failed to exec process \(error)")
            }
            throw ArgumentParser.ExitCode(exitCode)
        }
    }
}
