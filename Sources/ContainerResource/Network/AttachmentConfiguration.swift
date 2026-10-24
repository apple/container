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

/// Configuration information for attaching a container network interface to a network.
public struct AttachmentConfiguration: Codable, Sendable {
    /// The network ID associated with the attachment.
    public let network: String

    /// The option information for the attachment
    public let options: AttachmentOptions

    public init(network: String, options: AttachmentOptions) {
        self.network = network
        self.options = options
    }
}

extension MACAddress {
    /// A locally-administered unicast MAC, assigned at create time so it and the
    /// IPv6 SLAAC address derived from it survive stop/start.
    public static func generate() -> MACAddress {
        MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
    }
}

// Option information for a network attachment.
public struct AttachmentOptions: Codable, Sendable {
    /// The hostname associated with the attachment.
    public let hostname: String

    /// The MAC address associated with the attachment (optional).
    public let macAddress: MACAddress?

    /// The MTU for the network interface.
    public let mtu: UInt32?

    /// Additional DNS names that resolve to the attachment.
    ///
    /// Each value is the normalized string form of a `DNSMatchRule`: an exact name such as
    /// `api.example.test`, or a name with a leading dot such as `.example.test` that matches every
    /// name below it. The list is empty when the attachment has no aliases.
    public let aliases: [String]

    /// Last assigned IPv4, re-offered on restart for a best-effort sticky IP
    /// (reassigned if taken).
    public let ipv4Address: IPv4Address?

    public init(
        hostname: String,
        macAddress: MACAddress? = nil,
        mtu: UInt32? = nil,
        aliases: [String] = [],
        ipv4Address: IPv4Address? = nil
    ) {
        self.hostname = hostname
        self.macAddress = macAddress
        self.mtu = mtu
        self.aliases = aliases
        self.ipv4Address = ipv4Address
    }

    private enum CodingKeys: String, CodingKey {
        case hostname
        case macAddress
        case mtu
        case aliases
        case ipv4Address
    }

    // Configurations stored before aliases existed have no `aliases` key, and decode with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try container.decode(String.self, forKey: .hostname)
        self.macAddress = try container.decodeIfPresent(MACAddress.self, forKey: .macAddress)
        self.mtu = try container.decodeIfPresent(UInt32.self, forKey: .mtu)
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.ipv4Address = try container.decodeIfPresent(IPv4Address.self, forKey: .ipv4Address)
    }

    // The key is left out when there are no aliases, so a configuration without them is stored as it was before.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostname, forKey: .hostname)
        try container.encodeIfPresent(macAddress, forKey: .macAddress)
        try container.encodeIfPresent(mtu, forKey: .mtu)
        if !aliases.isEmpty {
            try container.encode(aliases, forKey: .aliases)
        }
        try container.encodeIfPresent(ipv4Address, forKey: .ipv4Address)
    }
}

extension AttachmentOptions {
    /// Returns the form of a hostname used to compare hostnames and to look them up.
    ///
    /// DNS names are case-insensitive, and a trailing dot only marks a name as fully qualified,
    /// so `Foo.Test.` and `foo.test` are the same name. The result is lowercase with any
    /// trailing dot removed.
    public static func canonicalHostname(_ hostname: String) -> String {
        let name = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        return name.lowercased()
    }
}
