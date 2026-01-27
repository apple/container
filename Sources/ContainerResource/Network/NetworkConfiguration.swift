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

import ContainerizationError
import ContainerizationExtras
import Foundation

/// Configuration parameters for network creation.
public struct NetworkConfiguration: Codable, Sendable, Identifiable {
    /// A unique identifier for the network
    public let id: String

    /// The network type
    public let mode: NetworkMode

    /// When the network was created.
    public let creationDate: Date

    /// The preferred CIDR address for the IPv4 subnet, if specified
    public let ipv4Subnet: CIDRv4?

    /// The preferred CIDR address for the IPv6 subnet, if specified
    public let ipv6Subnet: CIDRv6?

    /// Key-value labels for the network.
    public var labels: [String: String] = [:]

    /// Creates a network configuration
    public init(
        id: String,
        mode: NetworkMode,
        ipv4Subnet: CIDRv4? = nil,
        ipv6Subnet: CIDRv6? = nil,
        labels: [String: String] = [:]
    ) throws {
        self.id = id
        self.creationDate = Date()
        self.mode = mode
        self.ipv4Subnet = ipv4Subnet
        self.ipv6Subnet = ipv6Subnet
        self.labels = labels
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case creationDate
        case mode
        case ipv4Subnet
        case ipv6Subnet
        case labels
        // TODO: retain for deserialization compatability for now, remove later
        case subnet
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date(timeIntervalSince1970: 0)
        mode = try container.decode(NetworkMode.self, forKey: .mode)
        let subnetText =
            try container.decodeIfPresent(String.self, forKey: .ipv4Subnet)
            ?? container.decodeIfPresent(String.self, forKey: .subnet)
        ipv4Subnet = try subnetText.map { try CIDRv4($0) }
        ipv6Subnet = try container.decodeIfPresent(String.self, forKey: .ipv6Subnet)
            .map { try CIDRv6($0) }
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        try validate()
    }

    /// Encode the configuration to the supplied Encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(ipv4Subnet, forKey: .ipv4Subnet)
        try container.encodeIfPresent(ipv6Subnet, forKey: .ipv6Subnet)
        try container.encode(labels, forKey: .labels)
    }

    private func validate() throws {
        guard id.isValidNetworkID() else {
            throw ContainerizationError(.invalidArgument, message: "invalid network ID: \(id)")
        }

        for (key, value) in labels {
            try validateLabel(key: key, value: value)
        }
    }

    /// TODO: Extract when we clean up client dependencies.
    private func validateLabel(key: String, value: String) throws {
        let keyLengthMax = 128
        let labelLengthMax = 4096
        guard key.count <= keyLengthMax else {
            throw ContainerizationError(.invalidArgument, message: "invalid label, key length is greater than \(keyLengthMax): \(key)")
        }

        guard key.isValidLabelKey() else {
            throw ContainerizationError(.invalidArgument, message: "invalid label key: \(key)")
        }

        let fullLabel = "\(key)=\(value)"
        guard fullLabel.count <= labelLengthMax else {
            throw ContainerizationError(.invalidArgument, message: "invalid label, key length is greater than \(labelLengthMax): \(fullLabel)")
        }
    }
}

extension String {
    /// Ensure that the network ID has the correct syntax.
    fileprivate func isValidNetworkID() -> Bool {
        let pattern = #"^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$"#
        return self.range(of: pattern, options: .regularExpression) != nil
    }

    /// Ensure label key conforms to OCI or Docker label guidelines.
    /// TODO: Extract when we clean up client dependencies.
    fileprivate func isValidLabelKey() -> Bool {
        let dockerPattern = #/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$/#
        let ociPattern = #/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?:/(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*))*$/#
        let dockerMatch = !self.ranges(of: dockerPattern).isEmpty
        let ociMatch = !self.ranges(of: ociPattern).isEmpty
        return dockerMatch || ociMatch
    }
}
