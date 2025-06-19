//
//  Secret.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level secret definition (primarily for Swarm).
struct Secret: Codable {
    let file: String? // Path to the file containing the secret content
    let environment: String? // Environment variable to populate with the secret content
    let external: ExternalSecret? // Indicates if the secret is external (pre-existing)
    let name: String? // Explicit name for the secret
    let labels: [String: String]? // Labels for the secret

    enum CodingKeys: String, CodingKey {
        case file, environment, external, name, labels
    }

    /// Custom initializer to handle `external: true` (boolean) or `external: { name: "my_sec" }` (object).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        environment = try container.decodeIfPresent(String.self, forKey: .environment)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)

        if let externalBool = try? container.decodeIfPresent(Bool.self, forKey: .external) {
            external = ExternalSecret(isExternal: externalBool, name: nil)
        } else if let externalDict = try? container.decodeIfPresent([String: String].self, forKey: .external) {
            external = ExternalSecret(isExternal: true, name: externalDict["name"])
        } else {
            external = nil
        }
    }
}