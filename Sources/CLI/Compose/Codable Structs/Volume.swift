//
//  Volume.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level volume definition.
struct Volume: Codable {
    let driver: String? // Volume driver (e.g., 'local')
    let driver_opts: [String: String]? // Driver-specific options
    let name: String? // Explicit name for the volume
    let labels: [String: String]? // Labels for the volume
    let external: ExternalVolume? // Indicates if the volume is external (pre-existing)

    enum CodingKeys: String, CodingKey {
        case driver, driver_opts, name, labels, external
    }

    /// Custom initializer to handle `external: true` (boolean) or `external: { name: "my_vol" }` (object).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driver = try container.decodeIfPresent(String.self, forKey: .driver)
        driver_opts = try container.decodeIfPresent([String: String].self, forKey: .driver_opts)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)

        if let externalBool = try? container.decodeIfPresent(Bool.self, forKey: .external) {
            external = ExternalVolume(isExternal: externalBool, name: nil)
        } else if let externalDict = try? container.decodeIfPresent([String: String].self, forKey: .external) {
            external = ExternalVolume(isExternal: true, name: externalDict["name"])
        } else {
            external = nil
        }
    }
    
    init(driver: String? = nil, driver_opts: [String : String]? = nil, name: String? = nil, labels: [String : String]? = nil, external: ExternalVolume? = nil) {
        self.driver = driver
        self.driver_opts = driver_opts
        self.name = name
        self.labels = labels
        self.external = external
    }
}
