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

/// Configuration parameters for network creation.
public struct NetworkConfiguration: Codable, Sendable, Identifiable {
    /// A unique identifier for the network
    public let id: String

    /// The network type
    public let mode: NetworkMode

    /// The preferred CIDR address for the subnet, if specified
    public let subnet: String?

    /// Key-value labels for the network.
    public var labels: [String: String] = [:]

    /// Creates a network configuration
    public init(
        id: String,
        mode: NetworkMode,
        subnet: String? = nil,
        labels: [String: String] = [:]
    ) {
        self.id = id
        self.mode = mode
        self.subnet = subnet
        self.labels = labels
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        mode = try container.decode(NetworkMode.self, forKey: .mode)
        subnet = try container.decodeIfPresent(String.self, forKey: .subnet)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}
