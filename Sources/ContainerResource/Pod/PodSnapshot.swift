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

/// A snapshot of a pod along with its configuration
/// and any runtime state information.
///
/// The shape follows the runtime interface's `PodSandboxStatus`.
/// https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
public struct PodSnapshot: Codable, Sendable {
    /// The configuration of the pod.
    public var configuration: PodConfiguration

    /// Identifier of the pod.
    public var id: String {
        configuration.id
    }

    /// Configured platform for the pod.
    public var platform: ContainerizationOCI.Platform {
        configuration.platform
    }

    /// The runtime state of the pod.
    public var state: PodState

    /// Network interfaces attached to the pod.
    public var networks: [Attachment]

    /// Identifiers of the containers in the pod.
    public var containers: [String]

    /// When the pod was started.
    public var startedDate: Date?

    public init(
        configuration: PodConfiguration,
        state: PodState,
        networks: [Attachment],
        containers: [String] = [],
        startedDate: Date? = nil
    ) {
        self.configuration = configuration
        self.state = state
        self.networks = networks
        self.containers = containers
        self.startedDate = startedDate
    }
}
