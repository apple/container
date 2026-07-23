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

import Foundation

/// The observed health status of a container, as derived from a periodic
/// healthcheck probe.
///
/// At present the daemon does not run a container-level healthcheck observer,
/// so ``ContainerSnapshot/health`` is always `nil`. This type is reserved for
/// downstream tools (e.g. `compose`) that want a stable shape to read from
/// once a healthcheck observer is wired into the API server.
public enum HealthStatus: String, CaseIterable, Sendable, Codable {
    /// No healthcheck has been configured or no result is yet available.
    case none
    /// The healthcheck is running but has not yet produced a successful probe.
    case starting
    /// The most recent probe(s) reported the container as healthy.
    case healthy
    /// The most recent probe(s) reported the container as unhealthy.
    case unhealthy
}
