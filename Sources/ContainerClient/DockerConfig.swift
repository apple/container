//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import Foundation

/// Represents the Docker configuration file structure
struct DockerConfig: Codable {
    /// Maps registry hosts to credential helper names
    let credHelpers: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case credHelpers
    }
}

/// Helper to read and parse Docker configuration
public struct DockerConfigReader: Sendable {
    private let configPath: URL
    
    /// Initialize with a custom config path
    public init(configPath: URL) {
        self.configPath = configPath
    }
    
    /// Initialize with default Docker config path (~/.docker/config.json)
    public init() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.configPath = homeDirectory.appendingPathComponent(".docker/config.json")
    }
    
    /// Get the credential helper name for a given registry host
    public func credentialHelper(for host: String) -> String? {
        guard let config = try? readConfig() else {
            return nil
        }
        return config.credHelpers?[host]
    }
    
    private func readConfig() throws -> DockerConfig {
        let data = try Data(contentsOf: configPath)
        let decoder = JSONDecoder()
        return try decoder.decode(DockerConfig.self, from: data)
    }
}
