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
/// The JSON encoding uses a single `status` object containing a `phase` field
/// alongside any runtime-allocated address properties, replacing the prior flat
/// `state`/`status` pair in the CLI output.
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
        case config
        case status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(config, forKey: .config)
        try container.encode(status, forKey: .status)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.config = try container.decode(NetworkConfiguration.self, forKey: .config)
        self.status = try container.decode(NetworkStatus.self, forKey: .status)
    }
}
