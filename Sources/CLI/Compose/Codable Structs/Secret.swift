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
//  Secret.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a top-level secret definition (primarily for Swarm).
struct Secret: Codable {
    /// Path to the file containing the secret content
    let file: String?
    /// Environment variable to populate with the secret content
    let environment: String?
    /// Indicates if the secret is external (pre-existing)
    let external: ExternalSecret?
    /// Explicit name for the secret
    let name: String?
    /// Labels for the secret
    let labels: [String: String]?

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
