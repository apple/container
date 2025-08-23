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

struct ComposePS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps",
        abstract: "List containers"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: Flags.Global
        
        @Flag(name: [.customLong("all"), .customShort("a")], help: "Show all containers (default shows just running)")
        var all: Bool = false
        
        @Flag(name: [.customLong("quiet"), .customShort("q")], help: "Only display container IDs")
        var quiet: Bool = false
        
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
            selectedServices: []
        )
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        
        // Get service statuses
        let statuses = try await orchestrator.ps(project: project)
        
        if quiet {
            // Just print container IDs
            for status in statuses where !status.containerID.isEmpty {
                print(status.containerID)
            }
        } else {
            // Print table
            var rows: [[String]] = [["NAME", "CONTAINER ID", "IMAGE", "STATUS", "PORTS"]]
            
            for status in statuses {
                rows.append([
                    status.name,
                    status.containerID.isEmpty ? "-" : String(status.containerID.prefix(12)),
                    status.image,
                    status.status,
                    status.ports
                ])
            }
            
            let table = TableOutput(rows: rows)
            print(table.format())
        }
        }
    }
