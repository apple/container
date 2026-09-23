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

    /// Last assigned IPv4, re-offered on restart for a best-effort sticky IP
    /// (reassigned if taken).
    public let ipv4Address: IPv4Address?

    public init(
        hostname: String,
        macAddress: MACAddress? = nil,
        mtu: UInt32? = nil,
        ipv4Address: IPv4Address? = nil
    ) {
        self.hostname = hostname
        self.macAddress = macAddress
        self.mtu = mtu
        self.ipv4Address = ipv4Address
    }
}
