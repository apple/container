//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

    public init(
        ipv4Subnet: CIDRv4,
        ipv4Gateway: IPv4Address
    ) {
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
    }

    enum CodingKeys: String, CodingKey {
        case ipv4Subnet
        case ipv4Gateway
    }

    /// Create a network status from the supplied Decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let addressText = try container.decode(String.self, forKey: .ipv4Subnet)
        ipv4Subnet = try CIDRv4(addressText)
        let gatewayText = try container.decode(String.self, forKey: .ipv4Gateway)
        ipv4Gateway = try IPv4Address(gatewayText)
    }

    /// Encode the network status to the supplied Encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(ipv4Subnet.description, forKey: .ipv4Subnet)
        try container.encode(ipv4Gateway.description, forKey: .ipv4Gateway)
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
