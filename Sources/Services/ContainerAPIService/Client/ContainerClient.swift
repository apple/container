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

/// A client for interacting with the container API server.
///
/// This client holds a reusable XPC connection and provides methods for
/// container lifecycle operations. All methods that operate on a specific
/// container take an `id` parameter.
public struct ContainerClient: Sendable {
    private static let serviceIdentifier = "com.apple.container.apiserver"

    private let xpcClient: XPCClient

    /// Creates a new container client with a connection to the API server.
    public init() {
        self.xpcClient = XPCClient(service: Self.serviceIdentifier)
    }

    @discardableResult
    private func xpcSend(
        message: XPCMessage,
        timeout: Duration? = XPCClient.xpcRegistrationTimeout
    ) async throws -> XPCMessage {
        try await xpcClient.send(message, responseTimeout: timeout)
    }

    /// Create a new container with the given configuration.
    public func create(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default,
        kernel: Kernel,
        initImage: String? = nil
    ) async throws {
        do {
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

            try await xpcSend(message: request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container",
                cause: error
            )
        }
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        do {
            let request = XPCMessage(route: .containerList)
            let filterData = try JSONEncoder().encode(filters)
            request.set(key: .listFilters, value: filterData)

            let response = try await xpcSend(
                message: request,
                timeout: .seconds(10)
            )
            let data = response.dataNoCopy(key: .containers)
            guard let data else {
                return []
            }
            return try JSONDecoder().decode([ContainerSnapshot].self, from: data)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to list containers",
                cause: error
            )
        }
    }

    /// Get the container for the provided id.
    public func get(id: String) async throws -> ContainerSnapshot {
        let containers = try await list(filters: ContainerListFilters(ids: [id]))
        guard let container = containers.first else {
            throw ContainerizationError(
                .notFound,
                message: "get failed: container \(id) not found"
            )
        }
        return container
    }

    /// Bootstrap the container's init process.
    public func bootstrap(id: String, stdio: [FileHandle?], variant: String? = nil) async throws -> ClientProcess {
        let request = XPCMessage(route: .containerBootstrap)

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

        if let variant {
            request.set(key: .variant, value: variant)
        }

        do {
            request.set(key: .id, value: id)
            try await xpcClient.send(request)
            return ClientProcessImpl(containerId: id, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to bootstrap container",
                cause: error
            )
        }
    }

    /// Send a signal to the container.
    public func kill(id: String, signal: Int32) async throws {
        do {
            let request = XPCMessage(route: .containerKill)
            request.set(key: .id, value: id)
            request.set(key: .processIdentifier, value: id)
            request.set(key: .signal, value: Int64(signal))

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill container",
                cause: error
            )
        }
    }

    /// Stop the container and all processes currently executing inside.
    public func stop(id: String, opts: ContainerStopOptions = ContainerStopOptions.default) async throws {
        do {
            let request = XPCMessage(route: .containerStop)
            let data = try JSONEncoder().encode(opts)
            request.set(key: .id, value: id)
            request.set(key: .stopOptions, value: data)

            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container",
                cause: error
            )
        }
    }

    /// Delete the container along with any resources.
    public func delete(id: String, force: Bool = false) async throws {
        do {
            let request = XPCMessage(route: .containerDelete)
            request.set(key: .id, value: id)
            request.set(key: .forceDelete, value: force)
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to delete container",
                cause: error
            )
        }
    }

    /// Get the disk usage for a container.
    public func diskUsage(id: String) async throws -> UInt64 {
        let request = XPCMessage(route: .containerDiskUsage)
        request.set(key: .id, value: id)
        let reply = try await xpcClient.send(request)

        let size = reply.uint64(key: .containerSize)
        return size
    }

    /// Create a new process inside a running container.
    /// The process is in a created state and must still be started.
    public func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> ClientProcess {
        do {
            let request = XPCMessage(route: .containerCreateProcess)
            request.set(key: .id, value: containerId)
            request.set(key: .processIdentifier, value: processId)

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

            try await xpcClient.send(request)
            return ClientProcessImpl(containerId: containerId, processId: processId, xpcClient: xpcClient)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create process in container",
                cause: error
            )
        }
    }

    /// Get the log file handles for a container.
    public func logs(id: String) async throws -> [FileHandle] {
        do {
            let request = XPCMessage(route: .containerLogs)
            request.set(key: .id, value: id)

            let response = try await xpcClient.send(request)
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
                message: "failed to get logs for container \(id)",
                cause: error
            )
        }
    }

    /// Dial a port on the container via vsock.
    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: .containerDial)
        request.set(key: .id, value: id)
        request.set(key: .port, value: UInt64(port))

        let response: XPCMessage
        do {
            response = try await xpcClient.send(request)
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

    /// Get resource usage statistics for a container.
    public func stats(id: String) async throws -> ContainerStats {
        let request = XPCMessage(route: .containerStats)
        request.set(key: .id, value: id)

        do {
            let response = try await xpcClient.send(request)
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
                message: "failed to get statistics for container \(id)",
                cause: error
            )
        }
    }

    public func export(id: String, archive: URL) async throws {
        let request = XPCMessage(route: .containerExport)
        request.set(key: .id, value: id)
        request.set(key: .archive, value: archive.absolutePath())

        do {
            try await xpcClient.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to export container",
                cause: error
            )
        }
    }
}
