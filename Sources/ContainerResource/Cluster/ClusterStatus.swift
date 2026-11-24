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

import Foundation

/// Aggregate health of a cluster, derived from the state of its nodes.
public enum ClusterState: String, Codable, Sendable {
    case running
    case degraded
    case stopped
}

/// The runtime state of a single cluster node.
public struct ClusterNodeState: Codable, Sendable, Equatable {
    public var name: String
    public var status: RuntimeStatus
    public var addresses: [String]?
    public var ports: [String]?

    public init(name: String, status: RuntimeStatus, addresses: [String]? = nil, ports: [String]? = nil) {
        self.name = name
        self.status = status
        self.addresses = addresses
        self.ports = ports
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, addresses, ports
    }

    /// Decodes a node state, ignoring unknown keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(RuntimeStatus.self, forKey: .status)
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses)
        ports = try container.decodeIfPresent([String].self, forKey: .ports)
    }
}

/// The runtime status of a cluster. Derived from live containers; never persisted.
public struct ClusterStatus: Codable, Sendable, Equatable {
    /// The aggregate state of the cluster.
    public var state: ClusterState

    /// The runtime state of each node, in the order they appear in the configuration.
    public var nodes: [ClusterNodeState]

    public init(state: ClusterState, nodes: [ClusterNodeState]) {
        self.state = state
        self.nodes = nodes
    }

    private enum CodingKeys: String, CodingKey {
        case state, nodes
    }

    /// Decodes a cluster status, ignoring unknown keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(ClusterState.self, forKey: .state)
        nodes = try container.decode([ClusterNodeState].self, forKey: .nodes)
    }
}
