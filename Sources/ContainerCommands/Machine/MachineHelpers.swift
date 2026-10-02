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

/// Boots a container machine and runs user setup inside the guest. Returns the
/// resulting snapshot.
///
/// User setup runs on every boot, not just the first: it's idempotent, so this
/// keeps the container user provisioned even if it's ever ended up in a
/// half-configured state. The setup script never needs a terminal or stdin,
/// so it always runs with `tty: false, interactive: false, detach: false`
/// regardless of the caller's own interactivity — this keeps signal
/// forwarding and cancellation working via `ProcessIO.handleProcess` (so
/// Ctrl-C during boot actually kills the setup process rather than hanging),
/// while still streaming its stderr live to the host so a caller like
/// `machine create`, which doesn't otherwise show the guest's output, can see
/// *why* setup refused to run (e.g. a uid/username/home conflict with an
/// existing account in the image).
///
/// On any failure during user setup the machine is stopped to leave it in a clean state.
@discardableResult
func bootMachine(
    id: String?,
    client: MachineClient,
    log: Logger
) async throws -> MachineSnapshot {
    var dynamicEnv: [String: String] = [:]
    if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
        dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
    }
    let snapshot = try await client.boot(id: id, dynamicEnv: dynamicEnv)

    do {
        guard let containerId = snapshot.containerId else {
            throw ContainerizationError(
                .invalidState,
                message: "container machine is running but has no container ID"
            )
        }

        let io = try ProcessIO.create(tty: false, interactive: false, detach: false)
        defer {
            try? io.close()
        }

        let processConfig = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", MachineUserSetup.script],
            environment: snapshot.configuration.processEnvironment,
            terminal: false
        )

        let process = try await ContainerClient().createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: processConfig,
            stdio: io.stdio)

        let exitCode = try await io.handleProcess(process: process, log: log)
        guard exitCode == 0 else {
            log.error("container machine user setup failed", metadata: ["id": "\(snapshot.id)", "exitCode": "\(exitCode)"])
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
