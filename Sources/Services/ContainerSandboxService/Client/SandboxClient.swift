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
import TerminalProgress

/// A client for interacting with a single sandbox.
public struct SandboxClient: Sendable {
    static let label = "com.apple.container.runtime"

    public static func machServiceLabel(runtime: String, id: String) -> String {
        "\(Self.label).\(runtime).\(id)"
    }

    private var machServiceLabel: String {
        Self.machServiceLabel(runtime: runtime, id: id)
    }

    let id: String
    let runtime: String
    let client: XPCClient

    init(id: String, runtime: String, client: XPCClient) {
        self.id = id
        self.runtime = runtime
        self.client = client
    }

    /// Create a SandboxClient by ID and runtime string. The returned client is ready to be used
    /// without additional steps.
    public static func create(id: String, runtime: String) async throws -> SandboxClient {
        let label = Self.machServiceLabel(runtime: runtime, id: id)
        let client = XPCClient(service: label)
        let request = XPCMessage(route: SandboxRoutes.createEndpoint.rawValue)

        let response: XPCMessage
        do {
            response = try await client.send(request, responseTimeout: .seconds(5))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container \(id)",
                cause: error
            )
        }
        guard let endpoint = response.endpoint(key: SandboxKeys.sandboxServiceEndpoint.rawValue) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get endpoint for sandbox service"
            )
        }

        let endpointConnection = xpc_connection_create_from_endpoint(endpoint)
        let xpcClient = XPCClient(connection: endpointConnection, label: label)
        return SandboxClient(id: id, runtime: runtime, client: xpcClient)
    }
}

// Runtime Methods
extension SandboxClient {
    public func bootstrap(stdio: [FileHandle?]) async throws {
        let request = XPCMessage(route: SandboxRoutes.bootstrap.rawValue)

        for (i, h) in stdio.enumerated() {
            let key: SandboxKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key.rawValue, value: h)
            }
        }

        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to bootstrap container \(self.id)",
                cause: error
            )
        }
    }

    public func state() async throws -> SandboxSnapshot {
        let request = XPCMessage(route: SandboxRoutes.state.rawValue)
        let response: XPCMessage
        do {
            response = try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get state for container \(self.id)",
                cause: error
            )
        }
        return try response.sandboxSnapshot()
    }

    public func createProcess(_ id: String, config: ProcessConfiguration, stdio: [FileHandle?]) async throws {
        let request = XPCMessage(route: SandboxRoutes.createProcess.rawValue)
        request.set(key: SandboxKeys.id.rawValue, value: id)
        let data = try JSONEncoder().encode(config)
        request.set(key: SandboxKeys.processConfig.rawValue, value: data)

        for (i, h) in stdio.enumerated() {
            let key: SandboxKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key.rawValue, value: h)
            }
        }

        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create process \(id) in container \(self.id)",
                cause: error
            )
        }
    }

    public func startProcess(_ id: String) async throws {
        let request = XPCMessage(route: SandboxRoutes.start.rawValue)
        request.set(key: SandboxKeys.id.rawValue, value: id)
        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to start process \(id) in container \(self.id)",
                cause: error
            )
        }
    }

    public func stop(options: ContainerStopOptions) async throws {
        let request = XPCMessage(route: SandboxRoutes.stop.rawValue)

        let data = try JSONEncoder().encode(options)
        request.set(key: SandboxKeys.stopOptions.rawValue, value: data)

        let responseTimeout = Duration(.seconds(Int64(options.timeoutInSeconds + 1)))
        do {
            try await self.client.send(request, responseTimeout: responseTimeout)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container \(self.id)",
                cause: error
            )
        }
    }

    public func kill(_ id: String, signal: Int64) async throws {
        let request = XPCMessage(route: SandboxRoutes.kill.rawValue)
        request.set(key: SandboxKeys.id.rawValue, value: id)
        request.set(key: SandboxKeys.signal.rawValue, value: signal)

        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to send signal \(signal) to process \(id) in container \(self.id)",
                cause: error
            )
        }
    }

    public func resize(_ id: String, size: Terminal.Size) async throws {
        let request = XPCMessage(route: SandboxRoutes.resize.rawValue)
        request.set(key: SandboxKeys.id.rawValue, value: id)
        request.set(key: SandboxKeys.width.rawValue, value: UInt64(size.width))
        request.set(key: SandboxKeys.height.rawValue, value: UInt64(size.height))

        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to resize pty for process \(id) in container \(self.id)",
                cause: error
            )
        }
    }

    public func wait(_ id: String) async throws -> ExitStatus {
        let request = XPCMessage(route: SandboxRoutes.wait.rawValue)
        request.set(key: SandboxKeys.id.rawValue, value: id)

        let response: XPCMessage
        do {
            response = try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to wait for process \(id) in container \(self.id)",
                cause: error
            )
        }
        let code = response.int64(key: SandboxKeys.exitCode.rawValue)
        let date = response.date(key: SandboxKeys.exitedAt.rawValue)
        return ExitStatus(exitCode: Int32(code), exitedAt: date)
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: SandboxRoutes.dial.rawValue)
        request.set(key: SandboxKeys.port.rawValue, value: UInt64(port))

        let response: XPCMessage
        do {
            response = try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to dial \(port) on \(self.id)",
                cause: error
            )
        }
        guard let fh = response.fileHandle(key: SandboxKeys.fd.rawValue) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get fd for vsock port \(port)"
            )
        }
        return fh
    }

    public func shutdown() async throws {
        let request = XPCMessage(route: SandboxRoutes.shutdown.rawValue)

        do {
            _ = try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to shutdown container \(self.id)",
                cause: error
            )
        }
    }

    public func statistics() async throws -> ContainerStats {
        let request = XPCMessage(route: SandboxRoutes.statistics.rawValue)

        let response: XPCMessage
        do {
            response = try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to get statistics for container \(self.id)",
                cause: error
            )
        }

        guard let data = response.dataNoCopy(key: SandboxKeys.statistics.rawValue) else {
            throw ContainerizationError(
                .internalError,
                message: "no statistics data returned"
            )
        }

        return try JSONDecoder().decode(ContainerStats.self, from: data)
    }
}

extension XPCMessage {
    public func id() throws -> String {
        let id = self.string(key: SandboxKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no id"
            )
        }
        return id
    }

    func sandboxSnapshot() throws -> SandboxSnapshot {
        let data = self.dataNoCopy(key: SandboxKeys.snapshot.rawValue)
        guard let data else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no state data returned"
            )
        }
        return try JSONDecoder().decode(SandboxSnapshot.self, from: data)
    }
}
