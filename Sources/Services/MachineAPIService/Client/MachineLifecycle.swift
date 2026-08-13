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

extension MachineClient {
    /// Boots a machine and performs its one-time user provisioning.
    ///
    /// This is shared by machine commands and specialized machine consumers so
    /// that every caller observes the same first-boot and failure behavior.
    @discardableResult
    public func bootAndInitialize(
        id: String?,
        dynamicEnv: [String: String] = [:],
        forwardSSHAgent: Bool = true,
        log: Logger,
        interactive: Bool
    ) async throws -> MachineSnapshot {
        var bootEnvironment = dynamicEnv
        if forwardSSHAgent,
            bootEnvironment["SSH_AUTH_SOCK"] == nil,
            let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        {
            bootEnvironment["SSH_AUTH_SOCK"] = sshAuthSock
        }

        let snapshot = try await boot(id: id, dynamicEnv: bootEnvironment)
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
                stdio: io.stdio
            )

            let exitCode = try await io.handleProcess(process: process, log: log)
            guard exitCode == 0 else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine failed to create user"
                )
            }
        } catch {
            try? await stop(id: snapshot.id)
            throw error
        }

        return try await inspect(id: snapshot.id)
    }
}
