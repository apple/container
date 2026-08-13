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
import ContainerPersistence
import ContainerVersion
import ContainerizationError
import Foundation
import Logging
import SystemPackage

public struct ComposeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Run Docker Compose inside a persistent container machine",
        usage: "container compose [--completions <bash|zsh|fish> | --socket-path | <subcommand> ...]",
        discussion: """
            Compose arguments are forwarded to the Docker Compose CLI inside the
            shared machine. The machine remains running after `compose down`.

            EXAMPLES:
              container compose up -d
              container compose -f compose.yaml config
              container compose exec api sh
              container compose version
              export DOCKER_HOST="$(container compose --socket-path)"
            """,
        version: ReleaseVersion.singleLine(appName: "compose")
    )

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Print a completion script for bash, zsh, or fish; cannot be combined with Compose arguments or --socket-path",
            valueName: "bash|zsh|fish"
        ),
        completion: .list(ComposeCompletionShell.allCases.map(\.rawValue))
    )
    var completions: ComposeCompletionShell? = nil

    @Flag(
        name: .long,
        help: "Print the host Docker socket endpoint; cannot be combined with --completions or Compose arguments"
    )
    var socketPath = false

    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Docker Compose subcommand and arguments", valueName: "subcommand")
    )
    var arguments: [String] = []

    public init() {}

    public func run() async throws {
        if let completions {
            guard !socketPath, arguments.isEmpty else {
                throw ValidationError("--completions cannot be combined with Compose arguments or --socket-path")
            }
            print(ComposeCompletionProvider.script(for: completions), terminator: "")
            return
        }

        if socketPath {
            guard arguments.isEmpty else {
                throw ValidationError("--socket-path cannot be combined with Compose arguments")
            }
            print(ComposeSocketEndpoint().dockerHost)
            return
        }

        if let reserved = ComposeInvocation.reservedOption(in: arguments) {
            throw ValidationError(
                "reserved plugin option '\(reserved.rawValue)' cannot be forwarded to Docker Compose"
            )
        }

        LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
        let log = Logger(label: "container.compose")
        let processRunner = ComposeProcessRunner()
        let manager = ComposeMachineManager(processRunner: processRunner)
        let snapshot = try await manager.ensureReady(log: log)
        let homeDirectory = FilePath(FileManager.default.homeDirectoryForCurrentUser.path)
        let currentDirectory = FilePath(FileManager.default.currentDirectoryPath)
        let workingDirectory = try ComposeEnvironment.workingDirectory(
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )
        let environment = try ComposeEnvironment.make(
            hostEnvironment: ProcessInfo.processInfo.environment,
            homeDirectory: homeDirectory,
            workingDirectory: currentDirectory
        )
        if ComposeInvocation.requestsHelp(in: arguments) {
            let result = try await processRunner.capture(
                snapshot: snapshot,
                executable: "/usr/bin/docker",
                arguments: ["compose"] + arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
            print(ComposeHelpOutput.rewrite(result.output), terminator: "")
            throw ArgumentParser.ExitCode(result.exitCode)
        }

        let exitCode = try await processRunner.run(
            snapshot: snapshot,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            log: log
        )
        throw ArgumentParser.ExitCode(exitCode)
    }
}
