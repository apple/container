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

import ContainerizationOCI
import Foundation

/// A snapshot of a container along with its configuration
/// and any runtime state information.
public struct ContainerSnapshot: Codable, Sendable {
    /// The configuration of the container.
    public var configuration: ContainerConfiguration

    /// Identifier of the container.
    public var id: String {
        configuration.id
    }

    /// Configured platform for the container.
    public var platform: ContainerizationOCI.Platform {
        configuration.platform
    }

    /// The runtime status of the container.
    public var status: RuntimeStatus
    /// Network interfaces attached to the sandbox that are provided to the container.
    public var networks: [Attachment]
    /// When the container was started.
    public var startedDate: Date?
    /// The exit code of the container's initial process, once it has exited.
    ///
    /// The engine already knew this — the runtime reports it and ExitMonitor
    /// acts on it — but it was dropped on the floor, so a stopped container was
    /// indistinguishable from one that had failed. `nil` while running, and for
    /// containers that were already stopped before the apiserver started.
    public var exitCode: Int32?
    /// When the container's initial process exited.
    public var exitedAt: Date?

    public init(
        configuration: ContainerConfiguration,
        status: RuntimeStatus,
        networks: [Attachment],
        startedDate: Date? = nil,
        exitCode: Int32? = nil,
        exitedAt: Date? = nil
    ) {
        self.configuration = configuration
        self.status = status
        self.networks = networks
        self.startedDate = startedDate
        self.exitCode = exitCode
        self.exitedAt = exitedAt
    }
}
