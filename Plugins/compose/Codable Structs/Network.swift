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
//  Network.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level network definition.
struct Network: Codable {
    /// Network driver (e.g., 'bridge', 'overlay')
    let driver: String?
    /// Driver-specific options
    let driver_opts: [String: String]?
    /// Allow standalone containers to attach to this network
    let attachable: Bool?
    /// Enable IPv6 networking
    let enable_ipv6: Bool?
    /// RENAMED: from `internal` to `isInternal` to avoid keyword clash
    let isInternal: Bool?
    /// Labels for the network
    let labels: [String: String]?
    /// Explicit name for the network
    let name: String?
    /// Indicates if the network is external (pre-existing)
    let external: ExternalNetwork?

    /// Updated CodingKeys to map 'internal' from YAML to 'isInternal' Swift property
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
