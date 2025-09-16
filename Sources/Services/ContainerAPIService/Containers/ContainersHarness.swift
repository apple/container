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

import ContainerClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging

public struct ContainersHarness: Sendable {
    let log: Logging.Logger
    let service: ContainersService

    public init(service: ContainersService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let containers = try await service.list()
        let data = try JSONEncoder().encode(containers)

        let reply = message.reply()
        reply.set(key: .containers, value: data)
        return reply
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .containerConfig)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "container configuration cannot be empty")
        }
        let kdata = message.dataNoCopy(key: .kernel)
        guard let kdata else {
            throw ContainerizationError(.invalidArgument, message: "kernel cannot be empty")
        }
        let odata = message.dataNoCopy(key: .containerOptions)
        var options: ContainerCreateOptions = .default
        if let odata {
            options = try JSONDecoder().decode(ContainerCreateOptions.self, from: odata)
        }
        let config = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        let kernel = try JSONDecoder().decode(Kernel.self, from: kdata)

        try await service.create(configuration: config, kernel: kernel, options: options)
        return message.reply()
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        let forceDelete = message.bool(key: .forceDelete)
        try await service.delete(id: id, force: forceDelete)
        return message.reply()
    }

    @Sendable
    public func logs(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let fds = try await service.logs(id: id)
        let reply = message.reply()
        try reply.set(key: .logs, value: fds)
        return reply
    }

    @Sendable
    public func eventHandler(_ message: XPCMessage) async throws -> XPCMessage {
        let event = try message.containerEvent()
        try await service.handleContainerEvents(event: event)
        return message.reply()
    }
}

extension XPCMessage {
    public func containerEvent() throws -> ContainerEvent {
        guard let data = self.dataNoCopy(key: .containerEvent) else {
            throw ContainerizationError(.invalidArgument, message: "Missing container event data")
        }
        let event = try JSONDecoder().decode(ContainerEvent.self, from: data)
        return event
    }
}
