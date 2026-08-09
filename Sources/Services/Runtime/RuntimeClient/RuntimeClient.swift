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
import ContainerizationOS
import Foundation
import TerminalProgress

/// A client for interacting with a container runtime service instance.
public struct RuntimeClient: Sendable {
    static let label = "com.apple.container.runtime"

    public static func machServiceLabel(runtime: String, id: String) -> String {
        "\(Self.label).\(runtime).\(id)"
    }

    private var machServiceLabel: String {
        Self.machServiceLabel(runtime: runtime, id: id)
    }

    /// The sandbox this client talks to, which is the container itself when
    /// the container has a machine of its own, and the pod when it shares one.
    let id: String
    /// The container in that sandbox the client addresses.
    /// The container a request is addressed to, when it is addressed to one.
    ///
    /// A sandbox's own calls name no container. A container's calls name it,
    /// however many containers the sandbox holds, so that no call has to be
    /// read as meaning the only one there.
    let containerId: String?
    let runtime: String
    let client: XPCClient

    init(id: String, containerId: String? = nil, runtime: String, client: XPCClient) {
        self.id = id
        self.containerId = containerId
        self.runtime = runtime
        self.client = client
    }

    /// The same client, addressing a different container in the same sandbox.
    public func addressing(_ containerId: String) -> RuntimeClient {
        RuntimeClient(id: self.id, containerId: containerId, runtime: self.runtime, client: self.client)
    }

    /// A request to the sandbox, naming the container it is addressed to. A
    /// sandbox holding one container still hears which container is meant.
    func request(_ route: String) -> XPCMessage {
        let message = XPCMessage(route: route)
        if let containerId = self.containerId {
            message.set(key: RuntimeKeys.containerId.rawValue, value: containerId)
        }
        return message
    }

    /// Create a RuntimeClient by ID and runtime string. The returned client is ready to be used
    /// without additional steps.
    public static func create(id: String, runtime: String, timeout: Duration = XPCClient.xpcRegistrationTimeout) async throws -> RuntimeClient {
        let label = Self.machServiceLabel(runtime: runtime, id: id)
        let client = XPCClient(service: label)
        let request = XPCMessage(route: RuntimeRoutes.createEndpoint.rawValue)

        let response: XPCMessage
        do {
            response = try await client.send(request, responseTimeout: timeout)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to create container \(id)",
                cause: error
            )
        }
        guard let endpoint = response.endpoint(key: RuntimeKeys.runtimeServiceEndpoint.rawValue) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get endpoint for runtime service"
            )
        }

        let endpointConnection = xpc_connection_create_from_endpoint(endpoint)
        let xpcClient = XPCClient(connection: endpointConnection, label: label)
        return RuntimeClient(id: id, runtime: runtime, client: xpcClient)
    }
}

// Runtime Methods
extension RuntimeClient {
    /// Run the sandbox with the containers it holds in it.
    ///
    /// The sandbox is brought up with every container named here in it, and
    /// asking again for one already up puts in whichever of them it does not
    /// hold yet. The standard streams belong to the container named by
    /// `stdioFor`, the one whose start this is; the rest are placed with none.
    public func bootstrap(
        bundlePaths: [String],
        stdioFor: String? = nil,
        stdio: [FileHandle?],
        networkBootstrapInfos: [NetworkBootstrapInfo],
        dynamicEnv: [String: String] = [:]
    ) async throws {
        let request = self.request(RuntimeRoutes.bootstrap.rawValue)
        try request.setStdio(stdio)

        do {
            let dynamicEnv = try JSONEncoder().encode(dynamicEnv)
            request.set(key: RuntimeKeys.dynamicEnv.rawValue, value: dynamicEnv)

            let pathsData = try JSONEncoder().encode(bundlePaths)
            request.set(key: RuntimeKeys.bundlePaths.rawValue, value: pathsData)
            if let stdioFor {
                request.set(key: RuntimeKeys.containerId.rawValue, value: stdioFor)
            }

            let infosData = try JSONEncoder().encode(networkBootstrapInfos)
            request.set(key: RuntimeKeys.networkBootstrapInfos.rawValue, value: infosData)
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to bootstrap container \(self.id)",
                cause: error
            )
        }
    }

    /// Hold the running sandbox to a memory size, which its containers share.
    public func setTargetMemorySize(_ bytes: UInt64) async throws {
        let request = self.request(RuntimeRoutes.updateResources.rawValue)
        request.set(key: RuntimeKeys.memoryInBytes.rawValue, value: bytes)
        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to set the memory size of sandbox \(self.id)",
                cause: error
            )
        }
    }

    public func state() async throws -> SandboxSnapshot {
        let request = self.request(RuntimeRoutes.state.rawValue)
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
        let request = self.request(RuntimeRoutes.createProcess.rawValue)
        request.set(key: RuntimeKeys.id.rawValue, value: id)
        let data = try JSONEncoder().encode(config)
        request.set(key: RuntimeKeys.processConfig.rawValue, value: data)

        for (i, h) in stdio.enumerated() {
            let key: RuntimeKeys = try {
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
        let request = self.request(RuntimeRoutes.start.rawValue)
        request.set(key: RuntimeKeys.id.rawValue, value: id)
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

    /// Stop the container this client addresses, leaving the machine it shares
    /// and the containers beside it running.
    public func stopContainer(options: ContainerStopOptions) async throws {
        let request = self.request(RuntimeRoutes.stopContainer.rawValue)

        let data = try JSONEncoder().encode(options)
        request.set(key: RuntimeKeys.stopOptions.rawValue, value: data)

        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container \(self.id)",
                cause: error
            )
        }
    }

    public func stop(options: ContainerStopOptions) async throws {
        let request = self.request(RuntimeRoutes.stop.rawValue)

        let data = try JSONEncoder().encode(options)
        request.set(key: RuntimeKeys.stopOptions.rawValue, value: data)

        do {
            try await self.client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to stop container \(self.id)",
                cause: error
            )
        }
    }

    public func kill(_ id: String, signal: String) async throws {
        let request = self.request(RuntimeRoutes.kill.rawValue)
        request.set(key: RuntimeKeys.id.rawValue, value: id)
        request.set(key: RuntimeKeys.signal.rawValue, value: signal)

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
        let request = self.request(RuntimeRoutes.resize.rawValue)
        request.set(key: RuntimeKeys.id.rawValue, value: id)
        request.set(key: RuntimeKeys.width.rawValue, value: UInt64(size.width))
        request.set(key: RuntimeKeys.height.rawValue, value: UInt64(size.height))

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
        let request = self.request(RuntimeRoutes.wait.rawValue)
        request.set(key: RuntimeKeys.id.rawValue, value: id)

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
        let code = response.int64(key: RuntimeKeys.exitCode.rawValue)
        let date = response.date(key: RuntimeKeys.exitedAt.rawValue)
        return ExitStatus(exitCode: Int32(code), exitedAt: date)
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        let request = self.request(RuntimeRoutes.dial.rawValue)
        request.set(key: RuntimeKeys.port.rawValue, value: UInt64(port))

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
        guard let fh = response.fileHandle(key: RuntimeKeys.fd.rawValue) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get fd for vsock port \(port)"
            )
        }
        return fh
    }

    public func shutdown() async throws {
        let request = self.request(RuntimeRoutes.shutdown.rawValue)

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

    public func copyIn(source: String, destination: String, mode: UInt32, createParents: Bool = true) async throws {
        let request = self.request(RuntimeRoutes.copyIn.rawValue)
        request.set(key: RuntimeKeys.sourcePath.rawValue, value: source)
        request.set(key: RuntimeKeys.destinationPath.rawValue, value: destination)
        request.set(key: RuntimeKeys.fileMode.rawValue, value: UInt64(mode))
        request.set(key: RuntimeKeys.createParents.rawValue, value: createParents)

        do {
            try await self.client.send(request, responseTimeout: .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to copy into container \(self.id)",
                cause: error
            )
        }
    }

    public func copyOut(source: String, destination: String, createParents: Bool = true) async throws {
        let request = self.request(RuntimeRoutes.copyOut.rawValue)
        request.set(key: RuntimeKeys.sourcePath.rawValue, value: source)
        request.set(key: RuntimeKeys.destinationPath.rawValue, value: destination)
        request.set(key: RuntimeKeys.createParents.rawValue, value: createParents)

        do {
            try await self.client.send(request, responseTimeout: .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to copy from container \(self.id)",
                cause: error
            )
        }
    }

    public func snapshotDisk(imagePath: String, destinationPath: String) async throws {
        let request = self.request(RuntimeRoutes.snapshotDisk.rawValue)
        request.set(key: RuntimeKeys.imagePath.rawValue, value: imagePath)
        request.set(key: RuntimeKeys.destinationPath.rawValue, value: destinationPath)

        do {
            try await self.client.send(request, responseTimeout: .seconds(300))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to snapshot disk in container \(self.id)",
                cause: error
            )
        }
    }

    public func statistics() async throws -> ContainerStats {
        let request = self.request(RuntimeRoutes.statistics.rawValue)

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

        guard let data = response.dataNoCopy(key: RuntimeKeys.statistics.rawValue) else {
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
        let id = self.string(key: RuntimeKeys.id.rawValue)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no id"
            )
        }
        return id
    }

    func sandboxSnapshot() throws -> SandboxSnapshot {
        let data = self.dataNoCopy(key: RuntimeKeys.snapshot.rawValue)
        guard let data else {
            throw ContainerizationError(
                .invalidArgument,
                message: "no state data returned"
            )
        }
        return try JSONDecoder().decode(SandboxSnapshot.self, from: data)
    }

    public func networkBootstrapInfos() throws -> [NetworkBootstrapInfo] {
        guard let data = self.dataNoCopy(key: RuntimeKeys.networkBootstrapInfos.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing networkBootstrapInfos in bootstrap message")
        }
        return try JSONDecoder().decode([NetworkBootstrapInfo].self, from: data)
    }

    /// Carry the standard streams of a container, in the order the guest
    /// numbers them.
    func setStdio(_ stdio: [FileHandle?]) throws {
        for (i, h) in stdio.enumerated() {
            let key: RuntimeKeys = try {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    throw ContainerizationError(.invalidArgument, message: "invalid fd \(i)")
                }
            }()

            if let h {
                self.set(key: key.rawValue, value: h)
            }
        }
    }
}
