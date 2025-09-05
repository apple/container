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


struct ComposeRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart services"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: Flags.Global
        
    @Option(name: [.customLong("timeout"), .customShort("t")], help: "Specify a shutdown timeout in seconds (default: 10)")
    var timeout: Int = 10

    @Argument(help: "Services to restart (omit to restart all)")
    var services: [String] = []

    @Flag(name: .long, help: "Disable healthchecks during orchestration")
    var noHealthcheck: Bool = false
        
        func run() async throws {
        // Set environment variables
        composeOptions.setEnvironmentVariables()
        
        // Parse compose file
        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: composeOptions.getComposeFileURLs())
        
        // Convert to project
        let converter = ProjectConverter(log: log)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: composeOptions.getProjectName(),
            profiles: composeOptions.profile,
            selectedServices: services
        )
        
        // Warn about requested services excluded by profiles or not present
        if !services.isEmpty {
            let requested = Set(services)
            let resolved = Set(project.services.keys)
            let missing = requested.subtracting(resolved)
            if !missing.isEmpty {
                let prof = composeOptions.profile
                let profStr = prof.isEmpty ? "(none)" : prof.joined(separator: ",")
                FileHandle.standardError.write(Data("compose: warning: skipping services not enabled by active profiles or not found: \(missing.sorted().joined(separator: ",")) (profiles=\(profStr))\n".utf8))
            }
        }

        // Early exit if nothing to restart
        if project.services.isEmpty {
            let prof = composeOptions.profile
            let profStr = prof.isEmpty ? "(none)" : prof.joined(separator: ",")
            print("No services matched the provided filters. Nothing to restart.")
            print("- Project: \(project.name)")
            if !services.isEmpty { print("- Services filter: \(services.joined(separator: ","))") }
            print("- Profiles: \(profStr)")
            return
        }
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        installDefaultTerminationHandlers()
        
        // Create progress bar
        let progressConfig = try ProgressConfig(
            description: "Restarting services",
            showTasks: true
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()
        
        // Restart services
        try await orchestrator.restart(
            project: project,
            services: services,
            timeout: timeout,
            disableHealthcheck: noHealthcheck,
            progressHandler: progress.handler
        )
        
        log.info("Services restarted")
        }
    }
