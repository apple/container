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
import ContainerizationError
import Foundation
import Logging
import MachineAPIClient

/// Resolves a container machine ID from an optional argument, falling back to the default machine.
func resolveMachineId(_ id: String?, client: MachineClient) async throws -> String {
    if let id {
        return id
    }
    guard let defaultId = try await client.getDefault() else {
        throw ContainerizationError(
            .invalidArgument,
            message: "no container machine specified and no default set"
        )
    }
    return defaultId
}

/// Boots a container machine and, on first ever boot, runs the in-VM init script
/// to set up the host user. Returns the resulting snapshot.
///
/// When `interactive` is true the init script is wired to the host's terminal
/// (used by `machine run`); otherwise it runs detached so non-TTY callers like
/// `machine create` don't require a TTY or pollute host stdout.
///
/// On any failure during user setup the machine is stopped to leave it in a clean state.
@discardableResult
func bootMachine(
    id: String?,
    client: MachineClient,
    log: Logger,
    interactive: Bool
) async throws -> MachineSnapshot {
    var dynamicEnv: [String: String] = [:]
    if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
        dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
    }
    let snapshot = try await client.boot(id: id, dynamicEnv: dynamicEnv)

    guard !snapshot.initialized else {
        return snapshot
    }

    do {
        guard let containerId = snapshot.containerId else {
            throw ContainerizationError(
                .invalidState,
                message: "container machine is running but has no container ID"
            )
        }

        let io = try ProcessIO.create(
            tty: interactive,
            interactive: interactive,
            detach: !interactive
        )
        defer {
            try? io.close()
        }

        let processConfig = ProcessConfiguration(
            executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
            arguments: ["-u"],
            environment: snapshot.configuration.processEnvironment,
            terminal: interactive
        )

        let process = try await ContainerClient().createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: processConfig,
            stdio: io.stdio)

        let exitCode = try await io.handleProcess(process: process, log: log)
        guard exitCode == 0 else {
            throw ContainerizationError(
                .invalidState,
                message: "container machine failed to create user"
            )
        }
    } catch {
        try? await client.stop(id: snapshot.id)
        throw error
    }

    return snapshot
}
