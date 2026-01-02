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

/// The network protocols available for port forwarding.
public enum PublishProtocol: String, Sendable, Codable {
    case tcp = "tcp"
    case udp = "udp"

    /// Initialize a protocol with to default value, `.tcp`.
    public init() {
        self = .tcp
    }

    /// Initialize a protocol value from the provided string.
    public init?(_ value: String) {
        switch value.lowercased() {
        case "tcp": self = .tcp
        case "udp": self = .udp
        default: return nil
        }
    }
}

/// Specifies internet port forwarding from host to container.
public struct PublishPort: Sendable, Codable {
    /// The IP address of the proxy listener on the host
    public let hostAddress: String

    /// The port number of the proxy listener on the host
    public let hostPort: UInt16

    /// The port number of the container listener
    public let containerPort: UInt16

    /// The network protocol for the proxy
    public let proto: PublishProtocol

    /// The number of ports to publish
    public let count: UInt16

    /// Creates a new port forwarding specification.
    public init(hostAddress: String, hostPort: UInt16, containerPort: UInt16, proto: PublishProtocol, count: UInt16) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.count = count
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        hostAddress = try container.decode(String.self, forKey: .hostAddress)
        hostPort = try container.decode(UInt16.self, forKey: .hostPort)
        containerPort = try container.decode(UInt16.self, forKey: .containerPort)
        proto = try container.decode(PublishProtocol.self, forKey: .proto)
        count = try container.decodeIfPresent(UInt16.self, forKey: .count) ?? 1
    }
}
