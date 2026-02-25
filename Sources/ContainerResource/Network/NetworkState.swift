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

    enum CodingKeys: String, CodingKey {
        case ipv4Subnet
        case ipv4Gateway
        case ipv6Subnet
        // TODO: retain for deserialization compatibility for now, remove later
        case address
        case gateway
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let address = try? container.decode(CIDRv4.self, forKey: .ipv4Subnet) {
            ipv4Subnet = address
        } else {
            ipv4Subnet = try container.decode(CIDRv4.self, forKey: .address)
        }
        if let gateway = try? container.decode(IPv4Address.self, forKey: .ipv4Gateway) {
            ipv4Gateway = gateway
        } else {
            ipv4Gateway = try container.decode(IPv4Address.self, forKey: .gateway)
        }
        ipv6Subnet = try container.decodeIfPresent(String.self, forKey: .ipv6Subnet)
            .map { try CIDRv6($0) }
    }

    /// Encode the configuration to the supplied Encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(ipv4Subnet, forKey: .ipv4Subnet)
        try container.encode(ipv4Gateway, forKey: .ipv4Gateway)
        try container.encodeIfPresent(ipv6Subnet, forKey: .ipv6Subnet)
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
        case .created(let config), .running(let config, _): config.id
        }
    }

    public var creationDate: Date {
        switch self {
        case .created(let config), .running(let config, _): config.creationDate
        }
    }

    public var isBuiltin: Bool {
        switch self {
        case .created(let config), .running(let config, _): config.labels.isBuiltin
        }
    }
}
