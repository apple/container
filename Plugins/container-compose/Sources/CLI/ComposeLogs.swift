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

struct ComposeLogs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "View output from containers"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: ComposeGlobalOptions
        
        @Flag(name: .long, help: "Follow log output")
        var follow: Bool = false
        
        @Option(name: .long, help: "Number of lines to show from the end of the logs")
        var tail: Int?
        
        @Flag(name: [.customLong("timestamps"), .customShort("t")], help: "Show timestamps")
    var timestamps: Bool = false

        @Flag(name: .long, help: "Include boot/system logs (vminitd) in output")
        var boot: Bool = false

        @Flag(name: .long, help: "Disable log prefixes (container-name |)")
        var noLogPrefix: Bool = false

        @Flag(name: .long, help: "Disable colored output")
        var noColor: Bool = false
        
        @Argument(help: "Services to display logs for")
        var services: [String] = []
        
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
            selectedServices: services
        )
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        // Install Ctrl-C handler to exit gracefully while following logs
        installDefaultTerminationHandlers()
        
        // Get logs stream
        let logStream = try await orchestrator.logs(
            project: project,
            services: services,
            follow: follow,
            tail: tail,
            timestamps: timestamps,
            includeBoot: boot
        )

        // Compute padding width for aligned prefixes
        let nameWidth = noLogPrefix ? nil : try await TargetsUtil.computePrefixWidth(project: project, services: services)

        // Print logs with container-name prefixes and optional timestamps
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        for try await entry in logStream {
            var output = ""
            if !noLogPrefix {
                output += LogPrefixFormatter.coloredPrefix(for: entry.containerName, width: nameWidth, colorEnabled: !noColor)
            }
            if timestamps {
                // If no prefix, don't double space
                if !output.isEmpty { output += " " }
                output += dateFormatter.string(from: entry.timestamp)
            }
            if !output.isEmpty { output += " " }
            output += entry.message
            
            switch entry.stream {
            case .stdout:
                print(output)
            case .stderr:
                FileHandle.standardError.write(Data((output + "\n").utf8))
            }
        }
        }
    }
