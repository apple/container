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

import ContainerizationError
import ContainerizationExtras

/// Configuration parameters for network creation.
public struct NetworkConfiguration: Codable, Sendable, Identifiable {
    /// A unique identifier for the network
    public let id: String

    /// The network type
    public let mode: NetworkMode

    /// The preferred CIDR address for the subnet, if specified
    public let subnet: String?

    /// Key-value labels for the network.
    public var labels: [String: String] = [:]

    /// Creates a network configuration
    public init(
        id: String,
        mode: NetworkMode,
        subnet: String? = nil,
        labels: [String: String] = [:]
    ) throws {
        self.id = id
        self.mode = mode
        self.subnet = subnet
        self.labels = labels
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case subnet
        case labels
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        mode = try container.decode(NetworkMode.self, forKey: .mode)
        subnet = try container.decodeIfPresent(String.self, forKey: .subnet)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        try validate()
    }

    private func validate() throws {
        guard id.isValidNetworkID() else {
            throw ContainerizationError(.invalidArgument, message: "invalid network ID: \(id)")
        }

        if let subnet {
            _ = try CIDRAddress(subnet)
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
