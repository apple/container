//
//  Config.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level config definition (primarily for Swarm).
struct Config: Codable {
    let file: String? // Path to the file containing the config content
    let external: ExternalConfig? // Indicates if the config is external (pre-existing)
    let name: String? // Explicit name for the config
    let labels: [String: String]? // Labels for the config

    enum CodingKeys: String, CodingKey {
        case file, external, name, labels
    }

    /// Custom initializer to handle `external: true` (boolean) or `external: { name: "my_cfg" }` (object).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)

        if let externalBool = try? container.decodeIfPresent(Bool.self, forKey: .external) {
            external = ExternalConfig(isExternal: externalBool, name: nil)
        } else if let externalDict = try? container.decodeIfPresent([String: String].self, forKey: .external) {
            external = ExternalConfig(isExternal: true, name: externalDict["name"])
        } else {
            external = nil
        }
    }
}