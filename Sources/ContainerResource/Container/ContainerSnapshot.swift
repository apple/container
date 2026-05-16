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
    /// The exit code of the container's init process. Nil while the
    /// container is running or has never been started. Populated when
    /// the container transitions to `.stopped`.
    public var exitCode: Int32?
    /// When the container's init process exited. Nil while the
    /// container is running or has never been started. Populated
    /// alongside `exitCode` on transition to `.stopped`.
    public var exitedDate: Date?

    public init(
        configuration: ContainerConfiguration,
        status: RuntimeStatus,
        networks: [Attachment],
        startedDate: Date? = nil,
        exitCode: Int32? = nil,
        exitedDate: Date? = nil
    ) {
        self.configuration = configuration
        self.status = status
        self.networks = networks
        self.startedDate = startedDate
        self.exitCode = exitCode
        self.exitedDate = exitedDate
    }
}
