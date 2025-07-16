//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

//
//  Deploy.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//


/// Represents the `deploy` configuration for a service (primarily for Swarm orchestration).
struct Deploy: Codable, Hashable {
    /// Deployment mode (e.g., 'replicated', 'global')
    let mode: String?
    /// Number of replicated service tasks
    let replicas: Int?
    /// Resource constraints (limits, reservations)
    let resources: DeployResources?
    /// Restart policy for tasks
    let restart_policy: DeployRestartPolicy?
}
