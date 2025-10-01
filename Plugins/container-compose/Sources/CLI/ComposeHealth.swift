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

/// Check health status of services in a compose project.
///
/// This command executes the health checks defined in the compose file
/// and reports the current health status of each service.
struct ComposeHealth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health",
        abstract: "Check health status of services"
    )
    
    @OptionGroup var composeOptions: ComposeOptions
    
    @OptionGroup var global: ComposeGlobalOptions
    
    @Argument(help: "Services to check (omit to check all)")
    var services: [String] = []
    
    @Flag(name: .shortAndLong, help: "Exit with non-zero status if any service is unhealthy")
    var quiet: Bool = false
    
    func run() async throws {
        global.configureLogging()
        
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
        profiles: composeOptions.profile
        )
        
        // Create orchestrator
        let orchestrator = Orchestrator(log: log)
        installDefaultTerminationHandlers()
        
        // Check health
        let healthStatus = try await orchestrator.checkHealth(
        project: project,
        services: services
        )
        
        if quiet {
        // In quiet mode, just exit with appropriate code
        let allHealthy = healthStatus.values.allSatisfy { $0 }
        throw ExitCode(allHealthy ? 0 : 1)
        } else {
        // Display health status
        if healthStatus.isEmpty {
            print("No services with health checks found")
        } else {
            for (service, isHealthy) in healthStatus.sorted(by: { $0.key < $1.key }) {
                let status = isHealthy ? "healthy" : "unhealthy"
                let symbol = isHealthy ? "✓" : "✗"
                print("\(symbol) \(service): \(status)")
            }
            
            // Exit with error if any unhealthy
            let allHealthy = healthStatus.values.allSatisfy { $0 }
            if !allHealthy {
                throw ExitCode.failure
            }
        }
        }
    }
}
