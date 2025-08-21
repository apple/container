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

import ContainerXPC
import ContainerizationError
import ContainerizationOS
import Foundation
import TerminalProgress

/// A client for interacting with a single sandbox.
public struct SandboxClient: Sendable, Codable {
    static let label = "com.apple.container.runtime"

    public static func machServiceLabel(runtime: String, id: String) -> String {
        "\(Self.label).\(runtime).\(id)"
    }

    private var machServiceLabel: String {
        Self.machServiceLabel(runtime: runtime, id: id)
    }

    let id: String
    let runtime: String

    /// Create a container.
    public init(id: String, runtime: String) {
        self.id = id
        self.runtime = runtime
    }
}

// Runtime Methods
extension SandboxClient {
    public func bootstrap(stdio: [FileHandle?]) async throws {
        let request = XPCMessage(route: SandboxRoutes.bootstrap.rawValue)
        let client = createClient()
        defer { client.close() }

        for (i, h) in stdio.enumerated() {
            let key: XPCKeys = {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    fatalError("invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key, value: h)
            }
        }

        try await client.send(request)
    }

    public func state() async throws -> SandboxSnapshot {
        let request = XPCMessage(route: SandboxRoutes.state.rawValue)
        let client = createClient()
        defer { client.close() }

        let response = try await client.send(request)
        return try response.sandboxSnapshot()
    }

    public func createProcess(_ id: String, config: ProcessConfiguration, stdio: [FileHandle?]) async throws {
        let request = XPCMessage(route: SandboxRoutes.createProcess.rawValue)
        request.set(key: .id, value: id)
        let data = try JSONEncoder().encode(config)
        request.set(key: .processConfig, value: data)

        for (i, h) in stdio.enumerated() {
            let key: XPCKeys = {
                switch i {
                case 0: .stdin
                case 1: .stdout
                case 2: .stderr
                default:
                    fatalError("invalid fd \(i)")
                }
            }()

            if let h {
                request.set(key: key, value: h)
            }
        }

        let client = createClient()
        defer { client.close() }
        try await client.send(request)
    }

    public func startProcess(_ id: String) async throws {
        let request = XPCMessage(route: SandboxRoutes.start.rawValue)
        request.set(key: .id, value: id)

        let client = createClient()
        defer { client.close() }

        try await client.send(request)
    }

    public func stop(options: ContainerStopOptions) async throws {
        let request = XPCMessage(route: SandboxRoutes.stop.rawValue)

        let data = try JSONEncoder().encode(options)
        request.set(key: .stopOptions, value: data)

        let client = createClient()
        defer { client.close() }
        let responseTimeout = Duration(.seconds(Int64(options.timeoutInSeconds + 1)))
        try await client.send(request, responseTimeout: responseTimeout)
    }

    public func kill(_ id: String, signal: Int64) async throws {
        let request = XPCMessage(route: SandboxRoutes.kill.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .signal, value: signal)

        let client = createClient()
        defer { client.close() }
        try await client.send(request)
    }

    public func resize(_ id: String, size: Terminal.Size) async throws {
        let request = XPCMessage(route: SandboxRoutes.resize.rawValue)
        request.set(key: .id, value: id)
        request.set(key: .width, value: UInt64(size.width))
        request.set(key: .height, value: UInt64(size.height))

        let client = createClient()
        defer { client.close() }
        try await client.send(request)
    }

    public func wait(_ id: String) async throws -> Int32 {
        let request = XPCMessage(route: SandboxRoutes.wait.rawValue)
        request.set(key: .id, value: id)

        let client = createClient()
        defer { client.close() }
        let response = try await client.send(request)
        let code = response.int64(key: .exitCode)
        return Int32(code)
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        let request = XPCMessage(route: SandboxRoutes.dial.rawValue)
        request.set(key: .port, value: UInt64(port))

        let client = createClient()
        defer { client.close() }

        let response = try await client.send(request)
        guard let fh = response.fileHandle(key: .fd) else {
            throw ContainerizationError(
                .internalError,
                message: "failed to get fd for vsock port \(port)"
            )
        }
        return fh
    }

    private func createClient() -> XPCClient {
        XPCClient(service: machServiceLabel)
    }
}

extension XPCMessage {
    public func id() throws -> String {
        let id = self.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "No id")
        }
        return id
    }

    func sandboxSnapshot() throws -> SandboxSnapshot {
        let data = self.dataNoCopy(key: .snapshot)
        guard let data else {
            throw ContainerizationError(.invalidArgument, message: "No state data returned")
        }
        return try JSONDecoder().decode(SandboxSnapshot.self, from: data)
    }
}
