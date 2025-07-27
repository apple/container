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
    @Option(name: [.customLong("file"), .customShort("f")], help: "Specify an alternate compose file")
    var file: String = "docker-compose.yaml"
    
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
    
    func getComposeFileURL() -> URL {
        if file.hasPrefix("/") {
            return URL(fileURLWithPath: file)
        } else {
            let currentPath = FileManager.default.currentDirectoryPath
            return URL(fileURLWithPath: currentPath).appendingPathComponent(file)
        }
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
