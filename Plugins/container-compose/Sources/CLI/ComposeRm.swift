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


struct ComposeRm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove stopped containers"
    )

    @OptionGroup
    var composeOptions: ComposeOptions

    @OptionGroup
    var global: ComposeGlobalOptions

    @Flag(name: .long, help: "Force removal of running containers")
    var force: Bool = false

    @Argument(help: "Services to remove (removes all if none specified)")
    var services: [String] = []

    func run() async throws {
        global.configureLogging()
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
            selectedServices: services.isEmpty ? [] : services
        )

        // Create progress handler
        let progressConfig = try ProgressConfig(
            description: "Removing containers",
            showTasks: true,
            showItems: false
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        installDefaultTerminationHandlers()

        // Remove containers
        let result = try await orchestrator.remove(
            project: project,
            services: services,
            force: force,
            progressHandler: progress.handler
        )

        progress.finish()

        if result.removedContainers.isEmpty {
            print("No containers to remove for project '\(project.name)'")
        } else {
            print("Removed containers for project '\(project.name)':")
            for container in result.removedContainers.sorted() {
                print("- \(container)")
            }
        }
    }
}
