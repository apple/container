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
import Foundation

extension Application {
    struct ComposeCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compose",
            abstract: "Manage multi-container applications",
            subcommands: [
                ComposeUp.self,
                ComposeDown.self,
                ComposePS.self,
                ComposeStart.self,
                ComposeStop.self,
                ComposeRestart.self,
                ComposeLogs.self,
                ComposeExec.self,
                ComposeHealth.self,
                ComposeValidate.self,
            ]
        )
    }
}

// MARK: - Shared Options

struct ComposeOptions: ParsableArguments {
    @Option(name: [.customLong("file"), .customShort("f")], help: "Specify compose file(s) (can be used multiple times)")
    var file: [String] = []
    
    @Option(name: [.customLong("project"), .customShort("p")], help: "Specify an alternate project name")
    var project: String?
    
    @Option(name: .long, help: "Specify a profile to enable")
    var profile: [String] = []
    
    @Option(name: .long, help: "Set an environment variable (can be used multiple times)")
    var env: [String] = []
    
    func getProjectName() -> String {
        if let project = project {
            return project
        }
        // Use current directory name as default project name
        let currentPath = FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: currentPath)
        return url.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
    }
    
    func getComposeFileURLs() -> [URL] {
        // If no files specified, use default
        let files = file.isEmpty ? ["docker-compose.yaml", "docker-compose.yml", "compose.yaml", "compose.yml"] : file
        
        var urls: [URL] = []
        let currentPath = FileManager.default.currentDirectoryPath
        
        for fileName in files {
            let url: URL
            if fileName.hasPrefix("/") {
                url = URL(fileURLWithPath: fileName)
            } else {
                url = URL(fileURLWithPath: currentPath).appendingPathComponent(fileName)
            }
            
            // For default files, only add if they exist
            if file.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    urls.append(url)
                    break // Use first found default file
                }
            } else {
                // For explicitly specified files, add them all (parser will check existence)
                urls.append(url)
            }
        }
        
        // If no files found from defaults, return the first default for error message
        if urls.isEmpty && file.isEmpty {
            let defaultFile = URL(fileURLWithPath: currentPath).appendingPathComponent("docker-compose.yaml")
            urls.append(defaultFile)
        }
        
        return urls
    }
    
    func setEnvironmentVariables() {
        for envVar in env {
            let parts = envVar.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                setenv(String(parts[0]), String(parts[1]), 1)
            }
        }
    }
}
