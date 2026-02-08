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
    public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let stdio = message.stdio()
        try await service.bootstrap(id: id, stdio: stdio)
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let stopOptions = try message.stopOptions()
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        try await service.stop(id: id, options: stopOptions)
        return message.reply()
    }

    @Sendable
    public func dial(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }

        let port = message.uint64(key: .port)
        let fh = try await service.dial(id: id, port: UInt32(port))
        let reply = message.reply()
        reply.setFileHandle(fh)

        return reply
    }

    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        let exitStatus = try await service.wait(id: id, processID: processID)
        let reply = message.reply()
        reply.set(key: .exitCode, value: Int64(exitStatus.exitCode))
        reply.set(key: .exitedAt, value: exitStatus.exitedAt)
        return reply
    }

    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        let width = message.uint64(key: .width)
        let height = message.uint64(key: .height)
        try await service.resize(
            id: id,
            processID: processID,
            size: Terminal.Size(width: UInt16(width), height: UInt16(height))
        )

        return message.reply()
    }

    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }
        try await service.kill(
            id: id,
            processID: processID,
            signal: try message.signal()
        )
        return message.reply()
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .containerConfig)
        guard let data else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container configuration cannot be empty"
            )
        }
        let kdata = message.dataNoCopy(key: .kernel)
        guard let kdata else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel cannot be empty"
            )
        }
        let odata = message.dataNoCopy(key: .containerOptions)
        var options: ContainerCreateOptions = .default
        if let odata {
            options = try JSONDecoder().decode(ContainerCreateOptions.self, from: odata)
        }
        let config = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        let kernel = try JSONDecoder().decode(Kernel.self, from: kdata)

        let initImage = message.string(key: .initImage)

        try await service.create(configuration: config, kernel: kernel, options: options, initImage: initImage)
        return message.reply()
    }

    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }
        let config = try message.processConfig()
        let stdio = message.stdio()

        try await service.createProcess(
            id: id,
            processID: processID,
            config: config,
            stdio: stdio
        )

        return message.reply()
    }

    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        try await service.startProcess(
            id: id,
            processID: processID,
        )

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
    public func diskUsage(_ message: XPCMessage) async throws -> XPCMessage {
        guard let containerId = message.string(key: .id) else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }

        let size = try await service.containerDiskUsage(id: containerId)

        let reply = message.reply()
        reply.set(key: .containerSize, value: size)
        return reply
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
    public func stats(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let stats = try await service.stats(id: id)
        let data = try JSONEncoder().encode(stats)
        let reply = message.reply()
        reply.set(key: .statistics, value: data)
        return reply
    }
}
