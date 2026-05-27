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

/// The runtime status of a network resource.
///
/// `phase` names the current lifecycle stage; the address fields are present
/// only when `phase` is `"running"` and are `nil` otherwise. Clients should
/// treat unrecognised `phase` values as unknown forward-compatible stages rather
/// than treating them as errors.
public struct NetworkStatus: Codable, Sendable {
    /// The current lifecycle phase of the network.
    ///
    /// Defined values: `"created"` (configured, plugin not yet active) and
    /// `"running"` (plugin active, subnet and gateway assigned).
    public let phase: String

    /// The allocated IPv4 subnet. Present only when `phase` is `"running"`.
    public let ipv4Subnet: CIDRv4?

    /// The IPv4 gateway address. Present only when `phase` is `"running"`.
    public let ipv4Gateway: IPv4Address?

    /// The allocated IPv6 subnet. Present only when `phase` is `"running"` and
    /// the network has IPv6 enabled.
    public let ipv6Subnet: CIDRv6?

    public init(
        phase: String,
        ipv4Subnet: CIDRv4? = nil,
        ipv4Gateway: IPv4Address? = nil,
        ipv6Subnet: CIDRv6? = nil
    ) {
        self.phase = phase
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Subnet = ipv6Subnet
    }
}

extension NetworkStatus {
    /// The status value for a network that is configured but not yet running.
    public static let created = NetworkStatus(phase: "created")

    /// Creates a running-phase status from a ``NetworkPluginStatus``.
    init(running networkStatus: NetworkPluginStatus) {
        self.init(
            phase: "running",
            ipv4Subnet: networkStatus.ipv4Subnet,
            ipv4Gateway: networkStatus.ipv4Gateway,
            ipv6Subnet: networkStatus.ipv6Subnet
        )
    }
}
