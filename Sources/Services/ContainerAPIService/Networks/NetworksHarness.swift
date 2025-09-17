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

import ContainerNetworkService
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
        let containers = try await service.list()
        let data = try JSONEncoder().encode(containers)

        let reply = message.reply()
        reply.set(key: .networkStates, value: data)
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

        let networkData = try JSONEncoder().encode(networkState)

        let reply = message.reply()
        reply.set(key: .networkState, value: networkData)
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
