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

import ContainerAPIClient
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging

public struct PodsHarness: Sendable {
    let log: Logging.Logger
    let service: PodsService

    public init(service: PodsService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        guard let data = message.dataNoCopy(key: .podConfig) else {
            throw ContainerizationError(.invalidArgument, message: "a pod configuration is required")
        }
        let configuration = try JSONDecoder().decode(PodConfiguration.self, from: data)

        guard let kernelData = message.dataNoCopy(key: .kernel) else {
            throw ContainerizationError(.invalidArgument, message: "a kernel is required")
        }
        let kernel = try JSONDecoder().decode(Kernel.self, from: kernelData)

        try await service.create(
            configuration: configuration,
            kernel: kernel,
            initImage: message.string(key: .initImage)
        )
        return message.reply()
    }

    @Sendable
    public func start(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .dynamicEnv)
        let dynamicEnv = try data.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let startup: PodsService.ContainerStartup? =
            dynamicEnv.isEmpty ? nil : .init(stdio: [nil, nil, nil], dynamicEnv: dynamicEnv)
        try await service.start(id: try message.podId(), startup: startup)
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        try await service.stop(id: try message.podId())
        return message.reply()
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        try await service.delete(id: try message.podId(), force: message.bool(key: .forceDelete))
        return message.reply()
    }

    @Sendable
    public func inspect(_ message: XPCMessage) async throws -> XPCMessage {
        let snapshot = try await service.inspect(id: try message.podId())
        let reply = message.reply()
        reply.set(key: .podSnapshot, value: try JSONEncoder().encode(snapshot))
        return reply
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let snapshots = await service.list()
        let reply = message.reply()
        reply.set(key: .podSnapshots, value: try JSONEncoder().encode(snapshots))
        return reply
    }

    @Sendable
    public func update(_ message: XPCMessage) async throws -> XPCMessage {
        let bytes = message.uint64(key: .memoryInBytes)
        guard bytes > 0 else {
            throw ContainerizationError(.invalidArgument, message: "a memory size is required")
        }
        try await service.update(id: try message.podId(), memoryInBytes: bytes)
        return message.reply()
    }
}

extension XPCMessage {
    fileprivate func podId() throws -> String {
        guard let id = self.string(key: .podId), !id.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "a pod name is required")
        }
        return id
    }
}
