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
//  Build.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents the `build` configuration for a service.
struct Build: Codable, Hashable {
    /// Path to the build context
    let context: String
    /// Optional path to the Dockerfile within the context
    let dockerfile: String?
    /// Build arguments
    let args: [String: String]?
    
    /// Custom initializer to handle `build: .` (string) or `build: { context: . }` (object)
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let contextString = try? container.decode(String.self) {
            self.context = contextString
            self.dockerfile = nil
            self.args = nil
        } else {
            let keyedContainer = try decoder.container(keyedBy: CodingKeys.self)
            self.context = try keyedContainer.decode(String.self, forKey: .context)
            self.dockerfile = try keyedContainer.decodeIfPresent(String.self, forKey: .dockerfile)
            self.args = try keyedContainer.decodeIfPresent([String: String].self, forKey: .args)
        }
    }

    enum CodingKeys: String, CodingKey {
        case context, dockerfile, args
    }
}
