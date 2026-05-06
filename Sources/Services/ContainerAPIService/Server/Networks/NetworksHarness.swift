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
import ContainerizationOS
import Foundation
import Logging

public struct NetworksHarness: Sendable {
    let log: Logging.Logger
    let service: NetworksService

    public init(service: NetworksService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let states = try await service.list()

        let reply = message.reply()

        // Current encoding: NetworkResource with status.phase shape (≥ 0.12.0).
        let resources = states.map(NetworkResource.init)
        reply.set(key: .networkResources, value: try JSONEncoder().encode(resources))

        // DEPRECATED 0.12.0 — retained for down-revision client compatibility.
        // Remove at next major version boundary.
        reply.set(key: .networkStates, value: try JSONEncoder().encode(states))

        return reply
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .networkConfig)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "network configuration cannot be empty")
        }

        let config = try JSONDecoder().decode(NetworkConfiguration.self, from: data)
        let networkState = try await service.create(configuration: config)

        let reply = message.reply()

        // Current encoding: NetworkResource with status.phase shape (≥ 0.12.0).
        reply.set(key: .networkResource, value: try JSONEncoder().encode(NetworkResource(networkState)))

        // DEPRECATED 0.12.0 — retained for down-revision client compatibility.
        // Remove at next major version boundary.
        reply.set(key: .networkState, value: try JSONEncoder().encode(networkState))

        return reply
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .networkId)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        try await service.delete(id: id)

        return message.reply()
    }
}
