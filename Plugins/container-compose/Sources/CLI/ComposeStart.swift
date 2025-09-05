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


struct ComposeStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start services"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: Flags.Global
        
        @Argument(help: "Services to start")
        var services: [String] = []
        
        func run() async throws {
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

        // Early exit if nothing to start
        if project.services.isEmpty {
            let prof = composeOptions.profile
            let profStr = prof.isEmpty ? "(none)" : prof.joined(separator: ",")
            print("No services matched the provided filters. Nothing to start.")
            print("- Project: \(project.name)")
            if !services.isEmpty { print("- Services filter: \(services.joined(separator: ","))") }
            print("- Profiles: \(profStr)")
            return
        }
        
        // Create progress handler
        let progressConfig = try ProgressConfig(
            description: "Starting services",
            showTasks: true,
            showItems: false
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        installDefaultTerminationHandlers()
        
        // Start services
        try await orchestrator.start(
            project: project,
            services: services,
            progressHandler: progress.handler
        )
        
        progress.finish()
        print("Started services for project '\(project.name)'")
        }
    }
