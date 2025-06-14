//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

public actor AllocationOnlyVmnetNetwork: Network {
    private let log: Logger
    private var _state: NetworkState

    /// Configure a bridge network that allows external system access using
    /// network address translation.
    public init(
        configuration: NetworkConfiguration,
        log: Logger
    ) throws {
        guard configuration.mode == .nat else {
            throw ContainerizationError(.unsupported, message: "invalid network mode \(configuration.mode)")
        }

        guard configuration.subnet == nil else {
            throw ContainerizationError(.unsupported, message: "subnet assignment is not yet implemented")
        }

        self.log = log
        self._state = .created(configuration)
    }

    public var state: NetworkState {
        self._state
    }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        try handler(nil)
    }

    public func start() async throws {
        guard case .created(let configuration) = _state else {
            throw ContainerizationError(.invalidState, message: "cannot start network \(_state.id) in \(_state.state) state")
        }
        var defaultSubnet = "192.168.64.1/24"

        log.info(
            "starting allocation-only network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(NetworkMode.nat.rawValue)",
            ]
        )

        if let suite = UserDefaults.init(suiteName: UserDefaults.appSuiteName) {
            // TODO: Make the suiteName a constant defined in ClientDefaults and use that.
            // This will need some re-working of dependencies between NetworkService and Client
            defaultSubnet = suite.string(forKey: "network.subnet") ?? defaultSubnet
        }

        let subnet = try CIDRAddress(defaultSubnet)
        let gateway = IPv4Address(fromValue: subnet.lower.value + 1)
        self._state = .running(configuration, NetworkStatus(address: subnet.description, gateway: gateway.description))
        log.info(
            "started allocation-only network",
            metadata: [
                "id": "\(configuration.id)",
                "mode": "\(configuration.mode)",
                "cidr": "\(defaultSubnet)",
            ]
        )
    }
}
