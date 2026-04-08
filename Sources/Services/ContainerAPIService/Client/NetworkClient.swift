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

import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation

public struct NetworkClient: Sendable {
    public static let defaultServiceIdentifier = "com.apple.container.apiserver"

    public static let defaultNetworkName = "default"
    public static let noNetworkName = "none"

    private let xpcClient: XPCClient

    /// Creates a new network client with a connection to the API server.
    public init(serviceIdentifier: String = Self.defaultServiceIdentifier) {
        self.xpcClient = XPCClient(service: serviceIdentifier)
    }

    @discardableResult
    private func xpcSend(
        message: XPCMessage,
        timeout: Duration? = XPCClient.xpcRegistrationTimeout
    ) async throws -> XPCMessage {
        try await xpcClient.send(message, responseTimeout: timeout)
    }

    public func create(configuration: NetworkConfiguration) async throws -> NetworkState {
        let request = XPCMessage(route: .networkCreate)
        request.set(key: .networkId, value: configuration.id)

        let data = try JSONEncoder().encode(configuration)
        request.set(key: .networkConfig, value: data)

        let response = try await xpcSend(message: request)
        let responseData = response.dataNoCopy(key: .networkState)
        guard let responseData else {
            throw ContainerizationError(.invalidArgument, message: "network configuration not received")
        }
        let state = try JSONDecoder().decode(NetworkState.self, from: responseData)
        return state
    }

    public func list() async throws -> [NetworkState] {
        let request = XPCMessage(route: .networkList)

        let response = try await xpcSend(message: request, timeout: .seconds(1))
        let responseData = response.dataNoCopy(key: .networkStates)
        guard let responseData else {
            return []
        }
        let states = try JSONDecoder().decode([NetworkState].self, from: responseData)
        return states
    }

    /// Get the network for the provided id.
    public func get(id: String) async throws -> NetworkState {
        let networks = try await list()
        guard let network = networks.first(where: { $0.id == id }) else {
            throw ContainerizationError(.notFound, message: "network \(id) not found")
        }
        return network
    }

    /// Delete the network with the given id.
    public func delete(id: String) async throws {
        let request = XPCMessage(route: .networkDelete)
        request.set(key: .networkId, value: id)
        try await xpcSend(message: request)
    }

    /// Retrieve the builtin network.
    public var builtin: NetworkState? {
        get async throws {
            try await list().first { $0.isBuiltin }
        }
    }
}
