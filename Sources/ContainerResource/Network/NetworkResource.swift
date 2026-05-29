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
/// intrinsic configuration from its ephemeral runtime status — following the same
/// config/status split used by Kubernetes and Docker. `config` is persisted;
/// `status` reflects what the network plugin reports at runtime.
///
/// JSON encoding produces four top-level keys: `id`, `state` (the lifecycle label:
/// `"created"` or `"running"`), `configuration` (the persistent config), and `status`
/// (runtime address properties, `null` when `state` is `"created"`).
public struct NetworkResource: ManagedResource {
    /// The network's configuration — its persistent, intrinsic properties.
    public let config: NetworkConfiguration

    /// The network's current status, including lifecycle phase and any
    /// runtime-allocated address properties.
    public let status: NetworkStatus

    // MARK: ManagedResource

    /// The unique identifier for this network. Identical to ``config/id``.
    public var id: String { config.id }

    /// The user-assigned name for this network. For networks, name and ID are the same.
    public var name: String { config.id }

    /// The time at which this network was created.
    public var creationDate: Date { config.creationDate }

    /// Key-value labels for this network.
    public var labels: ResourceLabels { config.labels }

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
    ///   - config: The network's intrinsic configuration.
    ///   - networkStatus: The plugin-reported runtime status, or `nil` if the
    ///     network is not yet running.
    public init(config: NetworkConfiguration, networkStatus: NetworkPluginStatus? = nil) {
        self.config = config
        self.status = networkStatus.map { NetworkStatus(running: $0) } ?? .created
    }
}

// MARK: - Conversion from NetworkState

extension NetworkResource {
    /// Creates a network resource from a ``NetworkState``.
    ///
    /// Used when translating from the internal plugin-protocol type to the
    /// public API surface type.
    public init(_ networkState: NetworkState) {
        switch networkState {
        case .created(let config):
            self.init(config: config)
        case .running(let config, let status):
            self.init(config: config, networkStatus: status)
        }
    }
}

// MARK: - Codable

extension NetworkResource {
    enum CodingKeys: String, CodingKey {
        case id
        case state
        case configuration
        case status
    }

    private enum StatusCodingKeys: String, CodingKey {
        case ipv4Subnet
        case ipv4Gateway
        case ipv6Subnet
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status.phase, forKey: .state)
        try container.encode(config, forKey: .configuration)
        if status.phase == "running" {
            var statusContainer = container.nestedContainer(keyedBy: StatusCodingKeys.self, forKey: .status)
            try statusContainer.encodeIfPresent(status.ipv4Subnet, forKey: .ipv4Subnet)
            try statusContainer.encodeIfPresent(status.ipv4Gateway, forKey: .ipv4Gateway)
            try statusContainer.encodeIfPresent(status.ipv6Subnet, forKey: .ipv6Subnet)
        } else {
            try container.encodeNil(forKey: .status)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        let config = try container.decode(NetworkConfiguration.self, forKey: .configuration)
        if try container.decodeNil(forKey: .status) {
            self.config = config
            self.status = NetworkStatus(phase: state)
        } else {
            let statusContainer = try container.nestedContainer(keyedBy: StatusCodingKeys.self, forKey: .status)
            self.config = config
            self.status = NetworkStatus(
                phase: state,
                ipv4Subnet: try statusContainer.decodeIfPresent(CIDRv4.self, forKey: .ipv4Subnet),
                ipv4Gateway: try statusContainer.decodeIfPresent(IPv4Address.self, forKey: .ipv4Gateway),
                ipv6Subnet: try statusContainer.decodeIfPresent(CIDRv6.self, forKey: .ipv6Subnet)
            )
        }
    }
}
