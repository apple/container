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

/// A client for managing virtual networks through the container API server.
///
/// `NetworkClient` communicates with `container-apiserver` over XPC to create,
/// list, inspect, and delete networks. Each instance holds a dedicated XPC
/// connection; create one client and reuse it across related operations.
///
/// ```swift
/// let client = NetworkClient()
/// let state = try await client.create(configuration: config)
/// let networks = try await client.list()
/// try await client.delete(id: state.id)
/// ```
public struct NetworkClient: Sendable {
    /// The Mach service name used to locate the container API server.
    ///
    /// Pass a different value to ``init(serviceIdentifier:)`` to connect to an
    /// alternative service endpoint, for example during testing.
    public static let defaultServiceIdentifier = "com.apple.container.apiserver"

    /// The name of the default network created automatically on first use.
    public static let defaultNetworkName = "default"

    /// The reserved name that indicates a container should have no network attachment.
    public static let noNetworkName = "none"

    private let xpcClient: XPCClient

    /// Creates a new network client connected to the given service endpoint.
    ///
    /// - Parameter serviceIdentifier: The Mach service name of the API server.
    ///   Defaults to ``defaultServiceIdentifier``.
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

    /// Creates a new network with the given configuration.
    ///
    /// The API server launches a network plugin instance for the new network and
    /// returns a ``NetworkState`` reflecting the network once it is running.
    ///
    /// - Parameter configuration: The configuration describing the network to create.
    /// - Returns: The running state of the newly created network.
    /// - Throws: ``ContainerizationError`` if the server does not return a valid
    ///   network state, or if the underlying XPC call fails.
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

    /// Returns the current state of all networks known to the API server.
    ///
    /// - Returns: An array of ``NetworkState`` values, or an empty array if no
    ///   networks exist or the server returns no data.
    /// - Throws: ``ContainerizationError`` if the underlying XPC call fails.
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

    /// Returns the network with the given identifier.
    ///
    /// - Parameter id: The identifier of the network to look up.
    /// - Returns: The ``NetworkState`` for the matching network.
    /// - Throws: ``ContainerizationError/notFound`` if no network with the given
    ///   identifier exists, or a communication error if the XPC call fails.
    public func get(id: String) async throws -> NetworkState {
        let networks = try await list()
        guard let network = networks.first(where: { $0.id == id }) else {
            throw ContainerizationError(.notFound, message: "network \(id) not found")
        }
        return network
    }

    /// Deletes the network with the given identifier.
    ///
    /// Deletion succeeds only when no containers are currently attached to the
    /// network. The default network cannot be deleted.
    ///
    /// - Parameter id: The identifier of the network to delete.
    /// - Throws: ``ContainerizationError`` if the network has active attachments,
    ///   if the network is the built-in default, or if the XPC call fails.
    public func delete(id: String) async throws {
        let request = XPCMessage(route: .networkDelete)
        request.set(key: .networkId, value: id)
        try await xpcSend(message: request)
    }

    /// The built-in network, if one exists.
    ///
    /// The built-in network is created automatically on first use and cannot be
    /// deleted. Returns `nil` if the API server cannot find a network with the
    /// built-in resource labels.
    ///
    /// - Throws: ``ContainerizationError`` if the underlying XPC call fails.
    public var builtin: NetworkState? {
        get async throws {
            try await list().first { $0.isBuiltin }
        }
    }
}
