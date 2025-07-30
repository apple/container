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
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress

public struct ClientContainer: Sendable, Codable {
    static let serviceIdentifier = "com.apple.container.apiserver"

    private var sandboxClient: SandboxClient {
        SandboxClient(id: configuration.id, runtime: configuration.runtimeHandler)
    }

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

    package init(configuration: ContainerConfiguration) {
        self.configuration = configuration
        self.status = .stopped
        self.networks = []
    }

    init(snapshot: ContainerSnapshot) {
        self.configuration = snapshot.configuration
        self.status = snapshot.status
        self.networks = snapshot.networks
    }

    public var initProcess: ClientProcess {
        ClientProcessImpl(containerId: self.id, client: self.sandboxClient)
    }
}

extension ClientContainer {
    private static func newClient() -> XPCClient {
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
        kernel: Kernel
    ) async throws -> ClientContainer {
        do {
            let client = Self.newClient()
            let request = XPCMessage(route: .createContainer)

            let data = try JSONEncoder().encode(configuration)
            let kdata = try JSONEncoder().encode(kernel)
            let odata = try JSONEncoder().encode(options)
            request.set(key: .containerConfig, value: data)
            request.set(key: .kernel, value: kdata)
            request.set(key: .containerOptions, value: odata)

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
            let client = Self.newClient()
            let request = XPCMessage(route: .listContainer)

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
        let client = self.sandboxClient
        try await client.bootstrap(stdio: stdio)
        return ClientProcessImpl(containerId: self.id, client: self.sandboxClient)
    }

    /// Stop the container and all processes currently executing inside.
    public func stop(opts: ContainerStopOptions = ContainerStopOptions.default) async throws {
        do {
            let client = self.sandboxClient
            try await client.stop(options: opts)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container",
                cause: error
            )
        }
    }

    /// Delete the container along with any resources.
    public func delete() async throws {
        do {
            let client = XPCClient(service: Self.serviceIdentifier)
            let request = XPCMessage(route: .deleteContainer)
            request.set(key: .id, value: self.id)
            try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to delete container",
                cause: error
            )
        }
    }
}

extension ClientContainer {
    /// Execute a new process inside a running container.
    public func createProcess(
        id: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        do {
            let client = self.sandboxClient
            try await client.createProcess(id, config: configuration, stdio: stdio)
            return ClientProcessImpl(containerId: self.id, processId: id, client: client)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to exec in container",
                cause: error
            )
        }
    }

    /// Send or "kill" a signal to the initial process of the container.
    /// Kill does not wait for the process to exit, it only delivers the signal.
    public func kill(_ signal: Int32) async throws {
        do {
            let client = self.sandboxClient
            try await client.kill(self.id, signal: Int64(signal))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill container \(self.id)",
                cause: error
            )
        }
    }

    public func logs() async throws -> [FileHandle] {
        do {
            let client = XPCClient(service: Self.serviceIdentifier)
            let request = XPCMessage(route: .containerLogs)
            request.set(key: .id, value: self.id)

            let response = try await client.send(request)
            let fds = response.fileHandles(key: .logs)
            guard let fds else {
                throw ContainerizationError(
                    .internalError,
                    message: "No log fds returned"
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
        do {
            let client = self.sandboxClient
            return try await client.dial(port)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to dial \(port) in container \(self.id)",
                cause: error
            )
        }
    }
}
