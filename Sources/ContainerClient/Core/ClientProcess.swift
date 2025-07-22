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
    /// Send or "kill" a signal to the process `id`.
    /// Kill does not wait for the process to exit, it only delivers the signal.
    func kill(_ signal: Int32) async throws
    ///  Wait for the process `id` to complete and return its exit code.
    /// This method blocks until the process exits and the code is obtained.
    func wait() async throws -> Int32
}

struct ClientProcessImpl: ClientProcess, Sendable {
    static let serviceIdentifier = "com.apple.container.apiserver"
    /// Identifier of the container.
    public let containerId: String

    private let client: SandboxClient

    /// Identifier of a process. That is running inside of a container.
    /// This field is nil if the process this objects refers to is the
    /// init process of the container.
    public let processId: String?

    public var id: String {
        processId ?? containerId
    }

    init(containerId: String, processId: String? = nil, client: SandboxClient) {
        self.containerId = containerId
        self.processId = processId
        self.client = client
    }

    /// Start the container and return the initial process.
    public func start() async throws {
        do {
            let client = self.client
            try await client.startProcess(self.id)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to start container",
                cause: error
            )
        }
    }

    public func kill(_ signal: Int32) async throws {
        do {

            let client = self.client
            try await client.kill(self.id, signal: Int64(signal))
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to kill process",
                cause: error
            )
        }
    }

    public func resize(_ size: ContainerizationOS.Terminal.Size) async throws {
        do {

            let client = self.client
            try await client.resize(self.id, size: size)

        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to resize process",
                cause: error
            )
        }
    }

    public func wait() async throws -> Int32 {
        do {
            let client = self.client
            return try await client.wait(self.id)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to wait on process",
                cause: error
            )
        }
    }
}
