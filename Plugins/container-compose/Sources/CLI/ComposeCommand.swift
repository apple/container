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
import ComposeCore

// This file now contains only shared options
// The main command is defined in main.swift

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
        let currentPath = FileManager.default.currentDirectoryPath
        
        // If files were explicitly specified, return all of them (relative to cwd)
        if !file.isEmpty {
            return file.map { name in
                if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
                return URL(fileURLWithPath: currentPath).appendingPathComponent(name)
            }
        }
        
        // Default behavior: detect base compose file and include matching override
        // Preferred order (first match wins):
        // 1) container-compose.yaml / container-compose.yml
        // 2) compose.yaml / compose.yml (Docker Compose v2 default)
        // 3) docker-compose.yaml / docker-compose.yml (legacy)
        let candidates = [
            "container-compose.yaml",
            "container-compose.yml",
            "compose.yaml",
            "compose.yml",
            "docker-compose.yaml",
            "docker-compose.yml",
        ]

        for base in candidates {
            let baseURL = URL(fileURLWithPath: currentPath).appendingPathComponent(base)
            if FileManager.default.fileExists(atPath: baseURL.path) {
                var urls = [baseURL]
                // Include override for the chosen base
                let overrideCandidates: [String]
                if base.hasPrefix("container-compose") {
                    overrideCandidates = ["container-compose.override.yaml", "container-compose.override.yml"]
                } else if base.hasPrefix("compose") {
                    overrideCandidates = ["compose.override.yaml", "compose.override.yml"]
                } else if base.hasPrefix("docker-compose") {
                    overrideCandidates = ["docker-compose.override.yml", "docker-compose.override.yaml"]
                } else {
                    overrideCandidates = []
                }
                for o in overrideCandidates {
                    let oURL = URL(fileURLWithPath: currentPath).appendingPathComponent(o)
                    if FileManager.default.fileExists(atPath: oURL.path) {
                        urls.append(oURL)
                    }
                }
                return urls
            }
        }
        
        // Nothing found: return a sensible default path for better error message downstream
        return [URL(fileURLWithPath: currentPath).appendingPathComponent("docker-compose.yml")]
    }
    
    func setEnvironmentVariables() {
        for envVar in env {
            let parts = envVar.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                setenv(String(parts[0]), String(parts[1]), 1)
            }
        }
    }

    /// Load .env from current working directory and export vars into process env
    /// Compose uses .env for interpolation; we approximate by exporting to env before parsing
    func loadDotEnvIfPresent() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        _ = EnvLoader.load(from: cwd, export: true, override: false)
    }
}
