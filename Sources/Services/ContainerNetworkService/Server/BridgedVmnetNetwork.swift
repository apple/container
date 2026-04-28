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

import ContainerNetworkServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import XPC

public actor BridgedVmnetNetwork: Network {
    // FIXME: NetworkPluginStatus requires non-optional ipv4Subnet/ipv4Gateway; use placeholder
    // values until the type is refactored to make them optional.
    private static let placeholderSubnet = try! CIDRv4("0.0.0.0/0")
    private static let placeholderGateway = IPv4Address(0)

    private let log: Logger
    private let hostInterface: String
    private var _state: NetworkState

    public init(configuration: NetworkConfiguration, log: Logger) throws {
        guard configuration.mode == .bridge else {
            throw ContainerizationError(.unsupported, message: "invalid network mode \(configuration.mode)")
        }
        guard let hostInterface = configuration.hostInterface else {
            throw ContainerizationError(.invalidArgument, message: "bridge network requires a host interface name")
        }
        self.log = log
        self.hostInterface = hostInterface
        self._state = .created(configuration)
    }

    public var state: NetworkState {
        self._state
    }

    public nonisolated func withAdditionalData(_ handler: (XPCMessage?) throws -> Void) throws {
        let msg = XPCMessage(object: xpc_dictionary_create_empty())
        msg.set(key: NetworkKeys.hostInterface.rawValue, value: hostInterface)
        try handler(msg)
    }

    public func start() async throws {
        guard case .created(let configuration) = _state else {
            throw ContainerizationError(.invalidState, message: "cannot start network \(_state.id) in \(_state.state) state")
        }

        log.info(
            "starting bridged network",
            metadata: [
                "id": "\(configuration.id)",
                "hostInterface": "\(hostInterface)",
            ]
        )

        let status = NetworkPluginStatus(
            ipv4Subnet: Self.placeholderSubnet,
            ipv4Gateway: Self.placeholderGateway,
            ipv6Subnet: nil,
        )
        self._state = .running(configuration, status)
        log.info(
            "started bridged network",
            metadata: [
                "id": "\(configuration.id)",
                "hostInterface": "\(hostInterface)",
            ]
        )
    }
}
