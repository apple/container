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

public struct NetworkStatus: Codable, Sendable {
    /// The address allocated for the network if no subnet was specified at
    /// creation time; otherwise, the subnet from the configuration.
    public let ipv4Subnet: CIDRv4

    /// The gateway IPv4 address.
    public let ipv4Gateway: IPv4Address

    /// The address allocated for the IPv6 network if no subnet was specified at
    /// creation time; otherwise, the IPv6 subnet from the configuration.
    /// The value is nil if the IPv6 subnet cannot be determined at creation time.
    public let ipv6Subnet: CIDRv6?

    public init(
        ipv4Subnet: CIDRv4,
        ipv4Gateway: IPv4Address,
        ipv6Subnet: CIDRv6?,
    ) {
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Subnet = ipv6Subnet
    }
}

/// The configuration and runtime attributes for a network.
public enum NetworkState: Codable, Sendable {
    // The network has been configured.
    case created(NetworkConfiguration)
    // The network is running.
    case running(NetworkConfiguration, NetworkStatus)

    public var state: String {
        switch self {
        case .created: "created"
        case .running: "running"
        }
    }

    public var id: String {
        switch self {
        case .created(let configuration): configuration.id
        case .running(let configuration, _): configuration.id
        }
    }

    public var creationDate: Date {
        switch self {
        case .created(let configuration): configuration.creationDate
        case .running(let configuration, _): configuration.creationDate
        }
    }
}
