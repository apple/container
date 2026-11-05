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

/// A cluster resource, representing a configured cluster and its runtime status.
///
/// `configuration` is persisted when the cluster is created; `status` is derived from
/// the cluster's node containers each time the resource is read.
///
/// JSON encoding produces three top-level keys: `id`, `configuration` and `status`.
public struct ClusterResource: ManagedResource, Equatable {
    /// The cluster's configuration — what the user asked for at create time.
    public let configuration: ClusterConfiguration

    /// The cluster's runtime status — its aggregate state and per-node state.
    public let status: ClusterStatus

    // MARK: ManagedResource

    /// The unique identifier for this cluster. Identical to ``configuration/name``.
    public var id: String { configuration.name }

    /// The user-assigned name for this cluster. For clusters, name and ID are the same.
    public var name: String { configuration.name }

    /// The time at which this cluster was created.
    public var creationDate: Date { configuration.creationDate }

    /// Key-value labels for this cluster.
    public var labels: ResourceLabels { configuration.labels }

    /// Returns `true` if `name` is safe to use as a cluster name and as a single path component:
    /// 1-63 ASCII letters, digits, `_`, `.` or `-`, starting with a letter or digit.
    /// Rejects `.`, `..`, empty names, and anything containing a path separator.
    public static func nameValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 63, let first = name.unicodeScalars.first, isAlphanumeric(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": return true
        default: return false
        }
    }

    // MARK: Initialization

    /// Creates a cluster resource.
    public init(configuration: ClusterConfiguration, status: ClusterStatus) {
        self.configuration = configuration
        self.status = status
    }
}

// MARK: - Codable

extension ClusterResource {
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
        configuration = try container.decode(ClusterConfiguration.self, forKey: .configuration)
        status = try container.decode(ClusterStatus.self, forKey: .status)
    }
}
