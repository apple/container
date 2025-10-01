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
import ContainerClient
import ComposeCore
import Foundation
import Logging

struct ComposeExec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Execute a command in a running container"
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
        // Load .env and set environment variables
        composeOptions.loadDotEnvIfPresent()
        composeOptions.setEnvironmentVariables()
        
        // Parse compose file
        let parser = ComposeParser(log: log, allowAnchors: global.allowAnchors)
        let composeFile = try parser.parse(from: composeOptions.getComposeFileURLs())
        
        // Convert to project
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: composeOptions.getProjectName(),
            profiles: composeOptions.profile,
            selectedServices: [service]
        )
        
        // Early validation and helpful messaging
        guard project.services.keys.contains(service) else {
            throw ValidationError("Service '\(service)' not found or not enabled by active profiles")
        }
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        
        // Execute command
        let exitCode = try await orchestrator.exec(
            project: project,
            serviceName: service,
            command: command,
            detach: detach,
            interactive: interactive,
            tty: tty,
            user: user,
            workdir: workdir,
            environment: envVars
        )
        
        // Exit with the same code as the executed command
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
        }
    }
