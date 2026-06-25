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

import ContainerizationOCI
import Foundation

/// A container as a managed resource. Wraps the persistent
/// ``ContainerConfiguration`` and a runtime ``ContainerStatus``.
public struct ManagedContainer: ManagedResource {
    public let configuration: ContainerConfiguration
    public let status: ContainerStatus

    // MARK: ManagedResource
    public var id: String { configuration.id }
    public var name: String { configuration.id }  // containers have no separate name field today

    public var creationDate: Date { configuration.creationDate }

    /// Typed labels for conformance / filtering. Drops labels that fail
    /// validation; the raw dictionary is preserved on `configuration.labels`
    /// and is what gets serialized.
    public var labels: ResourceLabels { (try? ResourceLabels(configuration.labels)) ?? .init() }

    /// Platform passthrough (parity with the former ContainerSnapshot.platform).
    public var platform: ContainerizationOCI.Platform { configuration.platform }

    /// Mint ids the way containers actually mint them (lowercased UUID),
    /// not the protocol's 64-hex default.
    public static func generateId() -> String { UUID().uuidString.lowercased() }

    /// Container name rule (mixed case, dots, hyphens, underscores). Duplicated from
    /// Utility.validEntityName
    public static func nameValid(_ name: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    public init(configuration: ContainerConfiguration, status: ContainerStatus) {
        self.configuration = configuration
        self.status = status
    }

    /// CLI-boundary factory: build from the snapshot the client returns today.
    public init(_ snapshot: ContainerSnapshot) {
        self.configuration = snapshot.configuration
        self.status = ContainerStatus(
            state: snapshot.status,
            networks: snapshot.networks,
            startedDate: snapshot.startedDate
        )
    }
}

extension ManagedContainer {
    enum CodingKeys: String, CodingKey { case id, configuration, status }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(status, forKey: .status)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.configuration = try c.decode(ContainerConfiguration.self, forKey: .configuration)
        self.status = try c.decode(ContainerStatus.self, forKey: .status)
    }
}
