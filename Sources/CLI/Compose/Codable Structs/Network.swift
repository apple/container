//
//  Network.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level network definition.
struct Network: Codable {
    let driver: String? // Network driver (e.g., 'bridge', 'overlay')
    let driver_opts: [String: String]? // Driver-specific options
    let attachable: Bool? // Allow standalone containers to attach to this network
    let enable_ipv6: Bool? // Enable IPv6 networking
    let isInternal: Bool? // RENAMED: from `internal` to `isInternal` to avoid keyword clash
    let labels: [String: String]? // Labels for the network
    let name: String? // Explicit name for the network
    let external: ExternalNetwork? // Indicates if the network is external (pre-existing)

    // Updated CodingKeys to map 'internal' from YAML to 'isInternal' Swift property
    enum CodingKeys: String, CodingKey {
        case driver, driver_opts, attachable, enable_ipv6, isInternal = "internal", labels, name, external
    }

    /// Custom initializer to handle `external: true` (boolean) or `external: { name: "my_net" }` (object).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        driver_opts = try container.decodeIfPresent([String: String].self, forKey: .driver_opts)
        attachable = try container.decodeIfPresent(Bool.self, forKey: .attachable)
        enable_ipv6 = try container.decodeIfPresent(Bool.self, forKey: .enable_ipv6)
        isInternal = try container.decodeIfPresent(Bool.self, forKey: .isInternal) // Use isInternal here
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)
        name = try container.decodeIfPresent(String.self, forKey: .name)

        if let externalBool = try? container.decodeIfPresent(Bool.self, forKey: .external) {
            external = ExternalNetwork(isExternal: externalBool, name: nil)
        } else if let externalDict = try? container.decodeIfPresent([String: String].self, forKey: .external) {
            external = ExternalNetwork(isExternal: true, name: externalDict["name"])
        } else {
            external = nil
        }
    }
}