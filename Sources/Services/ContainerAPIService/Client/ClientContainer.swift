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
import ContainerizationOCI
import Foundation
import TerminalProgress

public struct ClientContainer: Sendable, Codable {
    static let serviceIdentifier = "com.apple.container.apiserver"

    /// Identifier of the container.
    public var id: String {
        configuration.id
    }

    public let status: RuntimeStatus

    /// Configured platform for the container.
    public var platform: ContainerizationOCI.Platform {
        configuration.platform
    }

    /// Configuration for the container.
    public let configuration: ContainerConfiguration

    /// Network allocated to the container.
    public let networks: [Attachment]

    /// When the container was started.
    public let startedDate: Date?

    package init(configuration: ContainerConfiguration) {
        self.configuration = configuration
        self.status = .stopped
        self.networks = []
        self.startedDate = nil
    }

    init(snapshot: ContainerSnapshot) {
        self.configuration = snapshot.configuration
        self.status = snapshot.status
        self.networks = snapshot.networks
        self.startedDate = snapshot.startedDate
    }
}

extension ClientContainer {
    private static func newXPCClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    @discardableResult
    private static func xpcSend(
        client: XPCClient,
        message: XPCMessage,
        timeout: Duration? = .seconds(15)
    ) async throws -> XPCMessage {
        try await client.send(message, responseTimeout: timeout)
    }

    public static func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default,
        kernel: Kernel,
        initImage: String? = nil
    ) async throws -> ClientContainer {
        do {
            let client = Self.newXPCClient()
            let request = XPCMessage(route: .containerCreate)

            let data = try JSONEncoder().encode(configuration)
            let kdata = try JSONEncoder().encode(kernel)
            let odata = try JSONEncoder().encode(options)
            request.set(key: .containerConfig, value: data)
            request.set(key: .kernel, value: kdata)
            request.set(key: .containerOptions, value: odata)

            if let initImage {
                request.set(key: .initImage, value: initImage)
            }

            try await xpcSend(client: client, message: request)
            return ClientContainer(configuration: configuration)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container",
                cause: error
            )
        }
    }

    public static func list() async throws -> [ClientContainer] {
        do {
            let client = Self.newXPCClient()
            let request = XPCMessage(route: .containerList)

            let response = try await xpcSend(
                client: client,
                message: request,
                timeout: .seconds(10)
            )
            let data = response.dataNoCopy(key: .containers)
            guard let data else {
                return []
            }
            let configs = try JSONDecoder().decode([ContainerSnapshot].self, from: data)
            return configs.map { ClientContainer(snapshot: $0) }
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to list containers",
                cause: error
            )
        }
    }

    /// Get the container for the provided id.
    public static func get(id: String) async throws -> ClientContainer {
        let containers = try await list()
        guard let container = containers.first(where: { $0.id == id }) else {
            throw ContainerizationError(
                .notFound,
                message: "get failed: container \(id) not found"
            )
        }
        return container
    }
}

extension ClientContainer {
    public func bootstrap(stdio: [FileHandle?]) async throws -> ClientProcess {
        let request = XPCMessage(route: .containerBootstrap)
        let client = Self.newXPCClient()

        for (i, h) in stdio.enumerated() {
            let key: XPCKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key, value: h)
            }
        }

        do {
            request.set(key: .id, value: self.id)
            try await client.send(request)
            return ClientProcessImpl(containerId: self.id, xpcClient: client)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to bootstrap container",
                cause: error
            )
        }
    }

    public func kill(_ signal: Int32) async throws {
        do {
            let request = XPCMessage(route: .containerKill)
            request.set(key: .id, value: self.id)
            request.set(key: .processIdentifier, value: self.id)
            request.set(key: .signal, value: Int64(signal))

            let client = Self.newXPCClient()
            try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill container",
                cause: error
            )
        }
    }

    /// Stop the container and all processes currently executing inside.
    public func stop(opts: ContainerStopOptions = ContainerStopOptions.default) async throws {
        do {
            let client = Self.newXPCClient()
            let request = XPCMessage(route: .containerStop)
            let data = try JSONEncoder().encode(opts)
            request.set(key: .id, value: self.id)
            request.set(key: .stopOptions, value: data)

            try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container",
                cause: error
            )
        }
    }

    /// Delete the container along with any resources.
    public func delete(force: Bool = false) async throws {
        do {
            let client = Self.newXPCClient()
            let request = XPCMessage(route: .containerDelete)
            request.set(key: .id, value: self.id)
            request.set(key: .forceDelete, value: force)
            try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to delete container",
                cause: error
            )
        }
    }

    public static func containerDiskUsage(id: String) async throws -> UInt64 {
        let client = Self.newXPCClient()
        let request = XPCMessage(route: .containerDiskUsage)
        request.set(key: .id, value: id)
        let reply = try await client.send(request)

        let size = reply.uint64(key: .containerSize)
        return size
    }

    /// Create a new process inside a running container. The process is in a
    /// created state and must still be started.
    public func createProcess(
        id: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        do {
            let request = XPCMessage(route: .containerCreateProcess)
            request.set(key: .id, value: self.id)
            request.set(key: .processIdentifier, value: id)

            let data = try JSONEncoder().encode(configuration)
            request.set(key: .processConfig, value: data)

            for (i, h) in stdio.enumerated() {
                let key: XPCKeys = try {
                    switch i {
                    case 0: .stdin
                    case 1: .stdout
                    case 2: .stderr
                    default:
                        throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                    }
                }()

                if let h {
                    request.set(key: key, value: h)
                }
            }

            let client = Self.newXPCClient()
            try await client.send(request)
            return ClientProcessImpl(containerId: self.id, processId: id, xpcClient: client)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create process in container",
                cause: error
            )
        }
    }

    public func logs() async throws -> [FileHandle] {
        do {
            let client = Self.newXPCClient()
            let request = XPCMessage(route: .containerLogs)
            request.set(key: .id, value: self.id)

            let response = try await client.send(request)
            let fds = response.fileHandles(key: .logs)
            guard let fds else {
                throw ContainerizationError(
                    .internalError,
                    message: "no log fds returned"
                )
            }
            return fds
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get logs for container \(self.id)",
                cause: error
            )
        }
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: .containerDial)
        request.set(key: .id, value: self.id)
        request.set(key: .port, value: UInt64(port))

        let client = Self.newXPCClient()
        let response: XPCMessage
        do {
            response = try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to dial port \(port) on container",
                cause: error
            )
        }
        guard let fh = response.fileHandle(key: .fd) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get fd for vsock port \(port)"
            )
        }
        return fh
    }

    public func stats() async throws -> ContainerStats {
        let request = XPCMessage(route: .containerStats)
        request.set(key: .id, value: self.id)

        let client = Self.newXPCClient()
        do {
            let response = try await client.send(request)
            guard let data = response.dataNoCopy(key: .statistics) else {
                throw ContainerizationError(
                    .internalError,
                    message: "no statistics data returned"
                )
            }
            return try JSONDecoder().decode(ContainerStats.self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get statistics for container \(self.id)",
                cause: error
            )
        }
    }
}
