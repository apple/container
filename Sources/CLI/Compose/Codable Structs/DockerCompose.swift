//
//  DockerCompose.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents the top-level structure of a docker-compose.yml file.
struct DockerCompose: Codable {
    let version: String? // The Compose file format version (e.g., '3.8')
    let name: String? // Optional project name
    let services: [String: Service] // Dictionary of service definitions, keyed by service name
    let volumes: [String: Volume]? // Optional top-level volume definitions
    let networks: [String: Network]? // Optional top-level network definitions
    let configs: [String: Config]? // Optional top-level config definitions (primarily for Swarm)
    let secrets: [String: Secret]? // Optional top-level secret definitions (primarily for Swarm)
    
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
