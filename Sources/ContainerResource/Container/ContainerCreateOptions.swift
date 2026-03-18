//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

public enum RestartPolicy: String, Sendable, Codable {
    case no
    case onFailure
    case always
}

public struct ContainerCreateOptions: Codable, Sendable {
    public let autoRemove: Bool
    public let restartPolicy: RestartPolicy

    public init(autoRemove: Bool, restartPolicy: RestartPolicy) {
        self.autoRemove = autoRemove
        self.restartPolicy = restartPolicy
    }

    public static let `default` = ContainerCreateOptions(autoRemove: false, restartPolicy: .no)

    enum CodingKeys: String, CodingKey {
        case autoRemove
        case restartPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        autoRemove = try container.decode(Bool.self, forKey: .autoRemove)
        restartPolicy = try container.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .no
    }
}
