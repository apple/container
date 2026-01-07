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

/// Disk usage statistics for all resource types
public struct DiskUsageStats: Sendable, Codable {
    /// Disk usage for images
    public var images: ResourceUsage

    /// Disk usage for containers
    public var containers: ResourceUsage

    /// Disk usage for volumes
    public var volumes: ResourceUsage

    public init(images: ResourceUsage, containers: ResourceUsage, volumes: ResourceUsage) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
    }
}

/// Disk usage statistics for a specific resource type
public struct ResourceUsage: Sendable, Codable {
    /// Total number of resources
    public var total: Int

    /// Number of active/running resources
    public var active: Int

    /// Total size in bytes
    public var sizeInBytes: UInt64

    /// Reclaimable size in bytes (from unused/inactive resources)
    public var reclaimable: UInt64

    public init(total: Int, active: Int, sizeInBytes: UInt64, reclaimable: UInt64) {
        self.total = total
        self.active = active
        self.sizeInBytes = sizeInBytes
        self.reclaimable = reclaimable
    }
}
