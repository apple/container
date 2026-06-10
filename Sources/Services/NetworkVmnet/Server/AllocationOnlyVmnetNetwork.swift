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

import ContainerNetworkServer
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Logging

public actor AllocationOnlyVmnetNetwork: Network {
    // The IPv4 subnet to be used if none explicitly passed in the `NetworkConfiguration`
    private static let defaultIPv4Subnet = try! CIDRv4("192.168.64.1/24")

    private let configuration: NetworkConfiguration
    private let log: Logger
    private var _status: NetworkStatus?

    /// Configure a bridge network that allows external system access using
    /// network address translation.
    public init(
        configuration: NetworkConfiguration,
        log: Logger
    ) throws {
        guard configuration.mode == .nat else {
            throw ContainerizationError(.unsupported, message: "invalid network mode \(configuration.mode)")
        }

        guard configuration.ipv6Subnet == nil else {
            throw ContainerizationError(.unsupported, message: "IPv6 subnet assignment is not yet implemented")
        }

        self.configuration = configuration
        self.log = log
        self._status = nil
    }

    public nonisolated var id: String { configuration.id }

    public var status: NetworkStatus? { _status }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        try handler(nil)
    }

    public func start() async throws {
        guard _status == nil else {
            throw ContainerizationError(.invalidState, message: "cannot start network \(configuration.id): already started")
        }

        log.info(
            "starting allocation-only network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(NetworkMode.nat.rawValue)",
            ]
        )

        let ipv4Subnet = configuration.ipv4Subnet ?? Self.defaultIPv4Subnet
        let gateway = IPv4Address(ipv4Subnet.lower.value + 1)
        self._status = NetworkStatus(
            ipv4Subnet: ipv4Subnet,
            ipv4Gateway: gateway,
            ipv6Subnet: nil
        )
        log.info(
            "started allocation-only network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(configuration.mode)",
                "cidr": "\(ipv4Subnet)",
            ]
        )
    }
}
