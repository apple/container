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
import ComposeCore
import Foundation
import Logging


struct ComposeStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop services"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: Flags.Global
        
        @Option(name: [.customLong("time"), .customShort("t")], help: "Specify a shutdown timeout in seconds")
        var timeout: Int = 10
        
        @Argument(help: "Services to stop")
        var services: [String] = []
        
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
        
        // Stop services
        try await orchestrator.stop(
            project: project,
            services: services,
            timeout: timeout,
            progressHandler: progress.handler
        )
        
        progress.finish()
        print("Stopped services for project '\(project.name)'")
        }
    }
