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


struct ComposeDown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "down",
        abstract: "Stop and remove containers, networks"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: Flags.Global
        
        @Flag(name: .long, help: "Remove named volumes declared in the volumes section")
        var volumes: Bool = false
        
        @Flag(name: .long, help: "Remove containers for services not in the compose file")
        var removeOrphans: Bool = false
        
        func run() async throws {
        // Set environment variables
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
            selectedServices: []
        )
        
        // Create progress handler
        let progressConfig = try ProgressConfig(
            description: "Stopping services",
            showTasks: true,
            showItems: false
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        // Allow Ctrl-C to stop the command cleanly
        installDefaultTerminationHandlers()
        
        // Stop services
        let result = try await orchestrator.down(
            project: project,
            removeVolumes: volumes,
            removeOrphans: removeOrphans,
            progressHandler: progress.handler
        )
        
        progress.finish()
        print("Stopped and removed project '\(project.name)'")
        if !result.removedContainers.isEmpty {
            print("Removed containers (\(result.removedContainers.count)):")
            for c in result.removedContainers.sorted() { print("- \(c)") }
        }
        if !result.removedVolumes.isEmpty {
            print("Removed volumes (\(result.removedVolumes.count)):")
            for v in result.removedVolumes.sorted() { print("- \(v)") }
        }
        }
    }
