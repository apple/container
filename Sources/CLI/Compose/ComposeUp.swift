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
import ContainerCompose
import ContainerizationError
import Foundation
import TerminalProgress

extension Application {
    struct ComposeUp: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "up",
            abstract: "Create and start containers"
        )
        
        @OptionGroup
        var composeOptions: ComposeOptions
        
        @OptionGroup
        var global: Flags.Global
        
        @Flag(name: [.customLong("detach"), .customShort("d")], help: "Run containers in the background")
        var detach: Bool = false
        
        @Flag(name: .long, help: "Remove containers for services not defined in the Compose file")
        var removeOrphans: Bool = false
        
        @Flag(name: .long, help: "Recreate containers even if their configuration hasn't changed")
        var forceRecreate: Bool = false
        
        @Flag(name: .long, help: "Don't recreate containers if they exist")
        var noRecreate: Bool = false
        
        @Flag(name: .long, help: "Don't start services after creating them")
        var noDeps: Bool = false
        
        @Argument(help: "Services to start")
        var services: [String] = []
        
        func run() async throws {
            // Set environment variables
            composeOptions.setEnvironmentVariables()
            
            // Parse compose files
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
                description: "Starting services",
                showTasks: true,
                showItems: false
            )
            let progress = ProgressBar(config: progressConfig)
            defer { progress.finish() }
            progress.start()
            
            // Create orchestrator
            let orchestrator = Orchestrator(log: log)
            
            // Start services
            try await orchestrator.up(
                project: project,
                services: services,
                detach: detach,
                forceRecreate: forceRecreate,
                noRecreate: noRecreate,
                progressHandler: progress.handler
            )
            
            progress.finish()
            
            if detach {
                print("Started project '\(project.name)' in detached mode")
            }
        }
    }
}