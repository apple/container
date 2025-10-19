//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

/// A snapshot of a sandbox and its resources.
public struct SandboxSnapshot: Codable, Sendable {
    /// The runtime status of the sandbox.
    public var status: RuntimeStatus
    /// Network attachments for the sandbox.
    public var networks: [Attachment]
    /// Containers placed in the sandbox.
    public var containers: [ContainerSnapshot]

    public init(
        status: RuntimeStatus,
        networks: [Attachment],
        containers: [ContainerSnapshot]
    ) {
        self.status = status
        self.networks = networks
        self.containers = containers
    }
}
