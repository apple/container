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

/// Filters for listing containers.
public struct ContainerListFilters: Sendable, Codable {
    /// Filter by container IDs. If non-empty, only containers with matching IDs are returned.
    public var ids: [String]
    /// Filter by container status.
    public var status: RuntimeStatus?
    /// Filter by labels. All specified labels must match.
    public var labels: [String: String]

    /// No filters applied. Will return all containers.
    public static let all = ContainerListFilters()

    public init(
        ids: [String] = [],
        status: RuntimeStatus? = nil,
        labels: [String: String] = [:]
    ) {
        self.ids = ids
        self.status = status
        self.labels = labels
    }
}
