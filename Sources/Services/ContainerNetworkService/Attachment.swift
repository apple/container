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

/// A snapshot of a network interface allocated to a sandbox.
public struct Attachment: Codable, Sendable {
    /// The network ID associated with the attachment.
    public let network: String
    /// The hostname associated with the attachment.
    public let hostname: String
    /// The CIDR address describing the interface IPv4 address, with the prefix length of the subnet.
    public let ipv4Address: CIDRv4
    /// The IPv4 gateway address.
    public let ipv4Gateway: IPv4Address
    /// The MAC address associated with the attachment (optional).
    public let macAddress: String?

    public init(network: String, hostname: String, ipv4Address: CIDRv4, ipv4Gateway: IPv4Address, macAddress: String? = nil) {
        self.network = network
        self.hostname = hostname
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
    }

    enum CodingKeys: String, CodingKey {
        case network
        case hostname
        case ipv4Address
        case ipv4Gateway
        case macAddress
    }

    /// Create an attachment from the supplied Decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        network = try container.decode(String.self, forKey: .network)
        hostname = try container.decode(String.self, forKey: .hostname)
        let addressText = try container.decode(String.self, forKey: .ipv4Address)
        ipv4Address = try CIDRv4(addressText)
        let gatewayText = try container.decode(String.self, forKey: .ipv4Gateway)
        ipv4Gateway = try IPv4Address(gatewayText)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
    }

    /// Encode the attachment to the supplied Encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(network, forKey: .network)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(ipv4Address.description, forKey: .ipv4Address)
        try container.encode(ipv4Gateway.description, forKey: .ipv4Gateway)
        try container.encodeIfPresent(macAddress, forKey: .macAddress)
    }
}
