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

struct ComposeValidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a compose file"
    )
    
    @OptionGroup
    var composeOptions: ComposeOptions
    
    @OptionGroup
    var global: Flags.Global
        
        @Flag(name: .long, help: "Don't print anything, just validate")
        var quiet: Bool = false
        
        func run() async throws {
        // Load .env and set environment variables
        composeOptions.loadDotEnvIfPresent()
        composeOptions.setEnvironmentVariables()
        
        // Parse compose file
        let parser = ComposeParser(log: log, allowAnchors: global.allowAnchors)
        let composeFile = try parser.parse(from: composeOptions.getComposeFileURLs())
        installDefaultTerminationHandlers()
        
        if !quiet {
            print("✓ Compose file is valid")
            let fileUrls = composeOptions.getComposeFileURLs()
            if fileUrls.count == 1 {
                print("  File: \(fileUrls[0].path)")
            } else {
                print("  Files:")
                for url in fileUrls {
                    print("    - \(url.path)")
                }
            }
            print("  Version: \(composeFile.version ?? "not specified")")
            print("  Services: \(composeFile.services.count)")
            
            for (name, service) in composeFile.services {
                print("    - \(name)")
                if let image = service.image {
                    print("      Image: \(image)")
                }
                if let profiles = service.profiles, !profiles.isEmpty {
                    print("      Profiles: \(profiles)")
                }
            }
            
            if let networks = composeFile.networks, !networks.isEmpty {
                print("  Networks: \(networks.count)")
                for (name, _) in networks {
                    print("    - \(name)")
                }
            }
            
            if let volumes = composeFile.volumes, !volumes.isEmpty {
                print("  Volumes: \(volumes.count)")
                for (name, _) in volumes {
                    print("    - \(name)")
                }
            }
        }
        }
    }
