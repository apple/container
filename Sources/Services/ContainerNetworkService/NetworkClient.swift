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

import ContainerXPC
import ContainerizationError
import Foundation

/// A client for interacting with a single network.
public struct NetworkClient: Sendable {
    // FIXME: need more flexibility than a hard-coded constant?
    static let label = "com.apple.container.network.container-network-vmnet"

    private var machServiceLabel: String {
        "\(Self.label).\(id)"
    }

    let id: String

    /// Create a client for a network.
    public init(id: String) {
        self.id = id
    }
}

// Runtime Methods
extension NetworkClient {
    public func state() async throws -> NetworkState {
        let request = XPCMessage(route: NetworkRoutes.state.rawValue)
        let client = createClient()

        let response = try await client.send(request)
        let state = try response.state()
        return state
    }

    public func allocate(hostname: String) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        let request = XPCMessage(route: NetworkRoutes.allocate.rawValue)
        request.set(key: NetworkKeys.hostname.rawValue, value: hostname)

        let client = createClient()

        let response = try await client.send(request)
        let attachment = try response.attachment()
        let additionalData = response.additionalData()
        return (attachment, additionalData)
    }

    public func deallocate(hostname: String) async throws {
        let request = XPCMessage(route: NetworkRoutes.deallocate.rawValue)
        request.set(key: NetworkKeys.hostname.rawValue, value: hostname)

        let client = createClient()
        try await client.send(request)
    }

    public func lookup(hostname: String) async throws -> Attachment? {
        let request = XPCMessage(route: NetworkRoutes.lookup.rawValue)
        request.set(key: NetworkKeys.hostname.rawValue, value: hostname)

        let client = createClient()

        let response = try await client.send(request)
        return try response.dataNoCopy(key: NetworkKeys.attachment.rawValue).map {
            try JSONDecoder().decode(Attachment.self, from: $0)
        }
    }

    public func disableAllocator() async throws -> Bool {
        let request = XPCMessage(route: NetworkRoutes.disableAllocator.rawValue)

        let client = createClient()

        let response = try await client.send(request)
        return try response.allocatorDisabled()
    }

    private func createClient() -> XPCClient {
        XPCClient(service: machServiceLabel)
    }
}

extension XPCMessage {
    func additionalData() -> XPCMessage? {
        guard let additionalData = xpc_dictionary_get_dictionary(self.underlying, NetworkKeys.additionalData.rawValue) else {
            return nil
        }
        return XPCMessage(object: additionalData)
    }

    func allocatorDisabled() throws -> Bool {
        self.bool(key: NetworkKeys.allocatorDisabled.rawValue)
    }

    func attachment() throws -> Attachment {
        let data = self.dataNoCopy(key: NetworkKeys.attachment.rawValue)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "No network attachment snapshot data in message")
        }
        return try JSONDecoder().decode(Attachment.self, from: data)
    }

    func hostname() throws -> String {
        let hostname = self.string(key: NetworkKeys.hostname.rawValue)
        guard let hostname else {
            throw ContainerizationError(.invalidArgument, message: "No hostname data in message")
        }
        return hostname
    }

    func state() throws -> NetworkState {
        let data = self.dataNoCopy(key: NetworkKeys.state.rawValue)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "No network snapshot data in message")
        }
        return try JSONDecoder().decode(NetworkState.self, from: data)
    }
}
