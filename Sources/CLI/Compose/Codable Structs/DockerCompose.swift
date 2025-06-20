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

//
//  DockerCompose.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents the top-level structure of a docker-compose.yml file.
struct DockerCompose: Codable {
    /// The Compose file format version (e.g., '3.8')
    let version: String?
    /// Optional project name
    let name: String?
    /// Dictionary of service definitions, keyed by service name
    let services: [String: Service]
    /// Optional top-level volume definitions
    let volumes: [String: Volume]?
    /// Optional top-level network definitions
    let networks: [String: Network]?
    /// Optional top-level config definitions (primarily for Swarm)
    let configs: [String: Config]?
    /// Optional top-level secret definitions (primarily for Swarm)
    let secrets: [String: Secret]?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        services = try container.decode([String: Service].self, forKey: .services)
        
        if let volumes = try container.decodeIfPresent([String: Optional<Volume>].self, forKey: .volumes) {
            let safeVolumes: [String : Volume] = volumes.mapValues { value in
                value ?? Volume()
            }
            self.volumes = safeVolumes
        } else {
            self.volumes = nil
        }
        networks = try container.decodeIfPresent([String: Network].self, forKey: .networks)
        configs = try container.decodeIfPresent([String: Config].self, forKey: .configs)
        secrets = try container.decodeIfPresent([String: Secret].self, forKey: .secrets)
    }
}
