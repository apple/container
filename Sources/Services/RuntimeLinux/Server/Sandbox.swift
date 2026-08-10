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

import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation

import struct ContainerizationOS.Terminal

/// The machine the runtime service drives, and the containers running in it.
///
/// A pod holds several containers and a standalone container holds one. The
/// service speaks to both the same way, naming the container it means, which
/// is how the runtime interface addresses a container in a sandbox.
/// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
protocol Sandbox: Sendable {
    /// Boot the machine and set up the containers registered in it.
    func create() async throws

    /// Start a container's init process.
    func startContainer(_ id: String) async throws

    /// Stop a container, leaving the machine running for the others.
    func stopContainer(_ id: String) async throws

    /// Take a stopped container out of the machine, so its name is free to
    /// place again.
    func removeContainer(_ id: String) async throws

    /// Signal a container's init process.
    func killContainer(_ id: String, signal: Signal) async throws

    /// Discard the free blocks of a container's root filesystem, returning
    /// the bytes the filesystem reported trimmed.
    @discardableResult
    func trimContainer(_ id: String) async throws -> UInt64

    /// Wait for a container's init process to exit.
    func waitContainer(_ id: String, timeoutInSeconds: Int64?) async throws -> ExitStatus

    /// Resize the terminal of a container's init process.
    func resizeContainer(_ id: String, to: Terminal.Size) async throws

    /// Run an additional process in a container.
    func execInContainer(
        _ id: String,
        processID: String,
        configuration: @Sendable @escaping (inout LinuxProcessConfiguration) throws -> Void
    ) async throws -> LinuxProcess

    /// Resource usage, for the named containers or for all of them.
    func statistics(containerIDs: [String]?, categories: StatCategory) async throws -> [ContainerStatistics]

    /// Act on a path in a container's filesystem.
    func filesystemOperation(_ id: String, operation: FilesystemOperation, path: String) async throws

    /// Copy a file or directory from the host into a container.
    func copyIn(_ id: String, from source: URL, to destination: URL, mode: UInt32, createParents: Bool) async throws

    /// Copy a file or directory out of a container to the host.
    func copyOut(_ id: String, from source: URL, to destination: URL, createParents: Bool) async throws

    /// Open a vsock connection to a port in the machine.
    func dialVsock(port: UInt32) async throws -> FileHandle

    /// Stop every container and power the machine off.
    func stop() async throws

    /// Ask the guest to hold itself to a memory size, which the machine's
    /// containers share.
    func setTargetMemorySize(_ bytes: UInt64) async throws
}

/// A pod already addresses its containers by name, so it is a sandbox as it
/// stands, save for the copies, which take a transfer size the runtime leaves
/// at its default.
extension LinuxPod: Sandbox {
    func copyIn(_ id: String, from source: URL, to destination: URL, mode: UInt32, createParents: Bool) async throws {
        try await self.copyIn(id, from: source, to: destination, mode: mode, createParents: createParents, chunkSize: Self.defaultCopyChunkSize)
    }

    func copyOut(_ id: String, from source: URL, to destination: URL, createParents: Bool) async throws {
        try await self.copyOut(id, from: source, to: destination, createParents: createParents, chunkSize: Self.defaultCopyChunkSize)
    }
}
