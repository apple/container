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

import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIOCore
import NIOPosix
import TerminalProgress

/// A protocol that defines the methods and data members available to a process
/// started inside of a container.
public protocol ClientProcess: Sendable {
    /// Identifier for the process.
    var id: String { get }

    /// Start the underlying process inside of the container.
    func start() async throws
    /// Send a terminal resize request to the process `id`.
    func resize(_ size: Terminal.Size) async throws
    /// Send a signal to the process `id`.
    /// Kill does not wait for the process to exit, it only delivers the signal.
    func kill(_ signal: Int32) async throws
    ///  Wait for the process `id` to complete and return its exit code.
    /// This method blocks until the process exits and the code is obtained.
    func wait() async throws -> Int32
}

struct ClientProcessImpl: ClientProcess, Sendable {
    static let serviceIdentifier = "com.apple.container.apiserver"

    /// ID of the process.
    public var id: String {
        processId ?? containerId
    }

    /// Identifier of the container.
    public let containerId: String

    /// Identifier of a process. That is running inside of a container.
    /// This field is nil if the process this objects refers to is the
    /// init process of the container.
    public let processId: String?

    private let xpcClient: XPCClient

    init(containerId: String, processId: String? = nil, xpcClient: XPCClient) {
        self.containerId = containerId
        self.processId = processId
        self.xpcClient = xpcClient
    }

    /// Start the process.
    public func start() async throws {
        let request = XPCMessage(route: .containerStartProcess)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: id)

        try await xpcClient.send(request)
    }

    /// Send a signal to the process.
    public func kill(_ signal: Int32) async throws {
        let request = XPCMessage(route: .containerKill)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: id)
        // The server reads `.signal` as a string and resolves it against the Linux
        // signal table, so send the canonical signal name rather than a raw integer.
        // A bare Int64 is read back as an empty string and rejected with
        // "missing signal in xpc message". Translating the host signal number to its
        // name (instead of sending the number) also keeps signals whose numbers differ
        // between macOS and Linux (e.g. SIGUSR1) correct. Fall back to the numeric
        // string for signals with no platform name (e.g. real-time signals).
        request.set(key: .signal, value: Signal.platformName(signal) ?? "\(signal)")

        try await xpcClient.send(request)
    }

    /// Resize the processes PTY if it has one.
    public func resize(_ size: Terminal.Size) async throws {
        let request = XPCMessage(route: .containerResize)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: id)
        request.set(key: .width, value: UInt64(size.width))
        request.set(key: .height, value: UInt64(size.height))

        try await xpcClient.send(request)
    }

    /// Wait for the process to exit.
    public func wait() async throws -> Int32 {
        let request = XPCMessage(route: .containerWait)
        request.set(key: .id, value: containerId)
        request.set(key: .processIdentifier, value: id)

        let response = try await xpcClient.send(request)
        let code = response.int64(key: .exitCode)
        return Int32(code)
    }
}
