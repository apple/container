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
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Foundation
import MachineAPIClient
import SystemPackage

extension Application {
    public struct MachineRun: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a command or interactive shell in a container machine, booting the container machine if necessary"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @OptionGroup(title: "Process options")
        var processFlags: Flags.Process

        @Option(name: [.short, .long], help: "Container machine ID (uses default if not specified)")
        var name: String?

        @Flag(name: .shortAndLong, help: "Run a process in a container machine and detach from it")
        public var detach = false

        @Flag(name: .long, help: "Run as root instead of matching host user")
        var root: Bool = false

        @Argument(help: "Command to run (default: login shell)")
        var executable: String?

        @Argument(parsing: .captureForPassthrough, help: "Command arguments")
        var arguments: [String] = []

        public func run() async throws {
            let client = MachineClient()
            let containerClient = ContainerClient()

            let snapshot = try await bootMachine(id: name, client: client, log: log, interactive: true)

            guard let containerId = snapshot.containerId else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine is running but has no container ID"
                )
            }
            // Default runs `/sbin.machine/init -s` to find the shell for user
            let executablePath = FilePath("/\(MachineBundle.sbinDirectory)").appending(MachineBundle.initFile).string

            let args: [String]
            let tty: Bool
            let interactive: Bool

            if let executable {
                args = ["-s", executable] + arguments
                tty = processFlags.tty
                interactive = processFlags.interactive
            } else {
                args = ["-s"]
                tty = true
                interactive = true
            }

            // If not root user, get default user from machine configuration
            let defaultUser: ProcessConfiguration.User = {
                if root || getuid() == 0 {
                    return .id(uid: 0, gid: 0)
                }

                return snapshot.configuration.user
            }()

            let (user, additionalGroups) = Parser.user(
                user: processFlags.user, uid: processFlags.uid,
                gid: processFlags.gid, defaultUser: defaultUser)

            let cwd = getWorkingDirectory(snapshot, user: user)

            // Build environment with HOME set correctly
            let envVars = try Parser.allEnv(
                imageEnvs: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
                envFiles: processFlags.envFile,
                envs: processFlags.env
            )

            let processConfig = ProcessConfiguration(
                executable: executablePath,
                arguments: args,
                environment: envVars,
                workingDirectory: cwd,
                terminal: tty,
                user: user,
                supplementalGroups: additionalGroups
            )

            let io = try ProcessIO.create(tty: tty, interactive: interactive, detach: detach)
            defer {
                try? io.close()
            }

            let process = try await containerClient.createProcess(
                containerId: containerId,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfig,
                stdio: io.stdio
            )

            if !tty {
                var handler = SignalThreshold(threshold: 3, signals: [SIGINT, SIGTERM])
                handler.start {
                    print("Received 3 SIGINT/SIGTERM's, forcefully exiting.")
                    Darwin.exit(1)
                }
            }

            if detach {
                try await process.start()
                try io.closeAfterStart()
                print(snapshot.id)
                return
            }

            let exitCode = try await io.handleProcess(process: process, log: log)
            throw ArgumentParser.ExitCode(exitCode)
        }

        func getWorkingDirectory(_ snapshot: MachineSnapshot, user: ProcessConfiguration.User) -> String {
            if let cwd = processFlags.cwd {
                return cwd
            }
            let fallback = user == snapshot.configuration.user ? snapshot.configuration.home : "/"
            if snapshot.bootConfig.homeMount == .none {
                return fallback
            }
            let home = FilePath(FileManager.default.homeDirectoryForCurrentUser.path)
            let cwd = FilePath(FileManager.default.currentDirectoryPath)
            guard cwd.starts(with: home) else {
                return fallback
            }
            return cwd.string
        }
    }
}
