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

import ContainerizationError
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
/// to set up the host user. The lifecycle implementation is shared with plugins.
@discardableResult
func bootMachine(
    id: String?,
    client: MachineClient,
    log: Logger,
    interactive: Bool
) async throws -> MachineSnapshot {
    try await client.bootAndInitialize(id: id, log: log, interactive: interactive)
}
