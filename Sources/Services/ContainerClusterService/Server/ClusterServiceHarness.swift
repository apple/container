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

import ContainerClusterServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

public struct ClusterServiceHarness: Sendable {
    let log: Logger
    let service: ClusterService

    public init(service: ClusterService, log: Logger) {
        self.log = log
        self.service = service
    }

    static func decodeConfiguration(_ message: XPCMessage) throws -> ClusterConfiguration {
        guard let data = message.dataNoCopy(key: .configuration) else {
            throw ContainerizationError(.invalidArgument, message: "missing cluster configuration")
        }
        do {
            return try JSONDecoder().decode(ClusterConfiguration.self, from: data)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "invalid cluster configuration: \(error)")
        }
    }

    static func decodeName(_ message: XPCMessage) throws -> String {
        guard let name = message.string(key: .name) else {
            throw ContainerizationError(.invalidArgument, message: "missing cluster name")
        }
        return name
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        let configuration = try Self.decodeConfiguration(message)
        let cluster = try await service.create(configuration: configuration)
        let reply = message.reply()
        reply.set(key: .cluster, value: try Self.encode(cluster))
        return reply
    }

    @Sendable
    public func get(_ message: XPCMessage) async throws -> XPCMessage {
        let name = try Self.decodeName(message)
        let info = try await service.get(name: name)
        let reply = message.reply()
        reply.set(key: .cluster, value: try Self.encode(info))
        return reply
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let infos = try await service.list()
        let reply = message.reply()
        reply.set(key: .clusters, value: try Self.encode(infos))
        return reply
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let name = try Self.decodeName(message)
        try await service.delete(name: name)
        return message.reply()
    }
}
