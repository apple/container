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
//  ServiceSecret.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents a service's usage of a secret.
struct ServiceSecret: Codable, Hashable {
    /// Name of the secret being used
    let source: String

    /// Path in the container where the secret will be mounted
    let target: String?

    /// User ID for the mounted secret file
    let uid: String?

    /// Group ID for the mounted secret file
    let gid: String?

    /// Permissions mode for the mounted secret file
    let mode: Int?

    /// Custom initializer to handle `secret_name` (string) or `{ source: secret_name, target: /path }` (object).
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let sourceName = try? container.decode(String.self) {
            self.source = sourceName
            self.target = nil
            self.uid = nil
            self.gid = nil
            self.mode = nil
        } else {
            let keyedContainer = try decoder.container(keyedBy: CodingKeys.self)
            self.source = try keyedContainer.decode(String.self, forKey: .source)
            self.target = try keyedContainer.decodeIfPresent(String.self, forKey: .target)
            self.uid = try keyedContainer.decodeIfPresent(String.self, forKey: .uid)
            self.gid = try keyedContainer.decodeIfPresent(String.self, forKey: .gid)
            self.mode = try keyedContainer.decodeIfPresent(Int.self, forKey: .mode)
        }
    }

    enum CodingKeys: String, CodingKey {
        case source, target, uid, gid, mode
    }
}
