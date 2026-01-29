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

public struct ClientNetwork {
    static let serviceIdentifier = "com.apple.container.apiserver"

    public static let defaultNetworkName = "default"
    public static let noNetworkName = "none"
}

extension ClientNetwork {
    private static func newClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    private static func xpcSend(
        client: XPCClient,
        message: XPCMessage,
        timeout: Duration? = .seconds(15)
    ) async throws -> XPCMessage {
        try await client.send(message, responseTimeout: timeout)
    }

    public static func create(configuration: NetworkConfiguration) async throws -> NetworkState {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkCreate)
        request.set(key: .networkId, value: configuration.id)

        let data = try JSONEncoder().encode(configuration)
        request.set(key: .networkConfig, value: data)

        let response = try await xpcSend(client: client, message: request)
        let responseData = response.dataNoCopy(key: .networkState)
        guard let responseData else {
            throw ContainerizationError(.invalidArgument, message: "network configuration not received")
        }
        let state = try JSONDecoder().decode(NetworkState.self, from: responseData)
        return state
    }

    public static func list() async throws -> [NetworkState] {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkList)

        let response = try await xpcSend(client: client, message: request, timeout: .seconds(1))
        let responseData = response.dataNoCopy(key: .networkStates)
        guard let responseData else {
            return []
        }
        let states = try JSONDecoder().decode([NetworkState].self, from: responseData)
        return states
    }

    /// Get the network for the provided id.
    public static func get(id: String) async throws -> NetworkState {
        let networks = try await list()
        guard let network = networks.first(where: { $0.id == id }) else {
            throw ContainerizationError(.notFound, message: "network \(id) not found")
        }
        return network
    }

    /// Delete the network with the given id.
    public static func delete(id: String) async throws {
        let client = Self.newClient()
        let request = XPCMessage(route: .networkDelete)
        request.set(key: .networkId, value: id)
        let _ = try await xpcSend(client: client, message: request)
    }

    /// Allocate an IP address from network `id`.
    public static func allocate(id: String, hostname: String, macAddress: MACAddress? = nil) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        let client = Self.newClient()

        let request = XPCMessage(route: .networkAllocate)
        request.set(key: .networkId, value: id)
        request.set(key: .networkHostname, value: hostname)
        if let macAddress = macAddress {
            request.set(key: .networkMACAddress, value: macAddress.description)
        }

        let response = try await xpcSend(client: client, message: request)
        let attachment = try response.attachment()
        let additionalData = response.additionalData()
        return (attachment, additionalData)
    }

    /// Deallocate a previously allocated IP address from network `id`.
    public static func deallocate(id: String, hostname: String) async throws {
        let client = Self.newClient()

        let request = XPCMessage(route: .networkDeallocate)
        request.set(key: .networkId, value: id)
        request.set(key: .networkHostname, value: hostname)
        let _ = try await xpcSend(client: client, message: request)
    }

    /// Lookup a hostname on network `id`.
    public static func lookup(id: String, hostname: String) async throws -> Attachment? {
        let client = Self.newClient()

        let request = XPCMessage(route: .networkLookup)
        request.set(key: .networkId, value: id)
        request.set(key: .networkHostname, value: hostname)

        let response = try await xpcSend(client: client, message: request)
        return try response.attachment()
    }

    /// Disable the IP allocator for network `id`.
    public static func disableAllocator(id: String) async throws -> Bool {
        let client = Self.newClient()

        let request = XPCMessage(route: .networkDisableAllocator)
        request.set(key: .networkId, value: id)

        let response = try await xpcSend(client: client, message: request)
        return try response.allocatorDisabled()
    }
}

extension XPCMessage {
    public func additionalData() -> XPCMessage? {
        guard let additionalData = xpc_dictionary_get_dictionary(self.underlying, XPCKeys.networkAdditionalData.rawValue) else {
            return nil
        }
        return XPCMessage(object: additionalData)
    }

    public func allocatorDisabled() throws -> Bool {
        self.bool(key: .networkDisableAllocator)
    }

    public func attachment() throws -> Attachment {
        let data = self.dataNoCopy(key: .networkAttachment)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "no network attachment snapshot data in message")
        }
        return try JSONDecoder().decode(Attachment.self, from: data)
    }

    public func hostname() throws -> String {
        let hostname = self.string(key: .networkHostname)
        guard let hostname else {
            throw ContainerizationError(.invalidArgument, message: "no hostname data in message")
        }
        return hostname
    }

    public func state() throws -> NetworkState {
        let data = self.dataNoCopy(key: .networkState)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "no network snapshot data in message")
        }
        return try JSONDecoder().decode(NetworkState.self, from: data)
    }
}
