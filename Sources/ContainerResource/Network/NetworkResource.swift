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

import ContainerizationExtras
import Foundation

/// A network resource, representing a configured virtual network and its runtime status.
///
/// `NetworkResource` conforms to `ManagedResource` and separates the network's
/// intrinsic configuration from its runtime status — following the same config/status
/// split used by Kubernetes and Docker. `configuration` is persisted; `status` reflects
/// what the network plugin reports at runtime.
///
/// JSON encoding produces three top-level keys: `id`, `configuration` (the persistent
/// config), and `status` (runtime address properties assigned by the network plugin).
public struct NetworkResource: ManagedResource {
    /// The network's configuration — its persistent, intrinsic properties.
    public let configuration: NetworkConfiguration

    /// The network's runtime status — the addresses assigned by the network plugin.
    public let status: NetworkStatus

    // MARK: ManagedResource

    /// The unique identifier for this network. Identical to ``configuration/name``.
    public var id: String { configuration.name }

    /// The user-assigned name for this network. For networks, name and ID are the same.
    public var name: String { configuration.name }

    /// The time at which this network was created.
    public var creationDate: Date { configuration.creationDate }

    /// Key-value labels for this network.
    public var labels: ResourceLabels { configuration.labels }

    /// Returns `true` for a system-managed network that cannot be deleted by the user.
    public var isBuiltin: Bool { labels.isBuiltin }

    /// Returns `true` if `name` is a syntactically valid network identifier.
    ///
    /// Valid network names are lowercase alphanumeric strings of up to 63
    /// characters, allowing dots, hyphens, and underscores in interior positions.
    public static func nameValid(_ name: String) -> Bool {
        let pattern = #"^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Initialization

    /// Creates a network resource.
    ///
    /// - Parameters:
    ///   - configuration: The network's intrinsic configuration.
    ///   - status: The runtime status reported by the network plugin.
    public init(configuration: NetworkConfiguration, status: NetworkStatus) {
        self.configuration = configuration
        self.status = status
    }
}

// MARK: - Codable

extension NetworkResource {
    enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(status, forKey: .status)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decode(NetworkConfiguration.self, forKey: .configuration)
        status = try container.decode(NetworkStatus.self, forKey: .status)
    }
}
