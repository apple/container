//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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
import ComposeCore
import Foundation

struct ComposeRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a one-off command on a service"
    )

    @OptionGroup
    var composeOptions: ComposeOptions

    @OptionGroup
    var global: ComposeGlobalOptions

    @Flag(name: [.customLong("detach"), .customShort("d")], help: "Run command in the background")
    var detach: Bool = false

    @Flag(name: [.customLong("interactive"), .customShort("i")], help: "Keep STDIN open even if not attached")
    var interactive: Bool = false

    @Flag(name: [.customLong("tty"), .customShort("t")], help: "Allocate a pseudo-TTY")
    var tty: Bool = false

    @Flag(name: [.customLong("no-tty"), .customShort("T")], help: "Disable pseudo-TTY allocation")
    var noTty: Bool = false

    @Flag(name: .long, help: "Don't start linked services")
    var noDeps: Bool = false

    @Flag(name: [.customLong("rm"), .customLong("remove")], help: "Automatically remove the container when it exits")
    var remove: Bool = false

    @Option(name: [.customLong("user"), .customShort("u")], help: "Username or UID")
    var user: String?

    @Option(name: [.customLong("workdir"), .customShort("w")], help: "Working directory inside the container")
    var workdir: String?

    @Option(name: [.customLong("env"), .customShort("e")], help: "Set environment variables")
    var envVars: [String] = []

    @Argument(help: "Service to run command in")
    var service: String

    @Argument(parsing: .captureForPassthrough, help: "Command to execute")
    var command: [String] = []

    func run() async throws {
        global.configureLogging()
        let fileURLs = composeOptions.getComposeFileURLs()
        composeOptions.prepareEnvironment(fileURLs: fileURLs)

        let parser = ComposeParser(log: log, allowAnchors: global.allowAnchors)
        let composeFile = try parser.parse(from: fileURLs)
        composeOptions.exportDotEnvForEnvFileExpansion(fileURLs: fileURLs)
        let projectDirectory = composeOptions.getProjectDirectory(fileURLs: fileURLs)
        let projectName = composeOptions.resolveProjectName(composeFile: composeFile, fileURLs: fileURLs)

        let converter = ProjectConverter(log: log, projectDirectory: projectDirectory)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: projectName,
            profiles: composeOptions.profile,
            selectedServices: [service]
        )

        guard project.services.keys.contains(service) else {
            throw ValidationError("Service '\(service)' not found or not enabled by active profiles")
        }

        let orchestrator = Orchestrator(log: log)
        let exitCode = try await orchestrator.run(
            project: project,
            serviceName: service,
            command: command,
            detach: detach,
            interactive: interactive,
            tty: noTty ? false : tty,
            user: user,
            workdir: workdir,
            environment: envVars,
            noDeps: noDeps,
            removeOnExit: remove
        )

        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }
}
