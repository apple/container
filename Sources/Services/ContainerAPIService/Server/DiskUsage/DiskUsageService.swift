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
import Logging

/// Service for calculating disk usage across all resource types
public actor DiskUsageService {
    private let containersService: ContainersService
    private let volumesService: VolumesService
    private let log: Logger

    public init(
        containersService: ContainersService,
        volumesService: VolumesService,
        log: Logger
    ) {
        self.containersService = containersService
        self.volumesService = volumesService
        self.log = log
    }

    /// Calculate disk usage for all resource types
    public func calculateDiskUsage() async throws -> DiskUsageStats {
        log.debug("calculating disk usage for all resources")

        // Get active image references first (needed for image calculation)
        let activeImageRefs = await containersService.getActiveImageReferences()

        // Query all services concurrently
        async let imageStats = ClientImage.calculateDiskUsage(activeReferences: activeImageRefs)
        async let containerStats = containersService.calculateDiskUsage()
        async let volumeStats = volumesService.calculateDiskUsage()

        let (imageData, containerData, volumeData) = try await (imageStats, containerStats, volumeStats)

        let stats = DiskUsageStats(
            images: ResourceUsage(
                total: imageData.totalCount,
                active: imageData.activeCount,
                sizeInBytes: imageData.totalSize,
                reclaimable: imageData.reclaimableSize
            ),
            containers: ResourceUsage(
                total: containerData.0,
                active: containerData.1,
                sizeInBytes: containerData.2,
                reclaimable: containerData.3
            ),
            volumes: ResourceUsage(
                total: volumeData.0,
                active: volumeData.1,
                sizeInBytes: volumeData.2,
                reclaimable: volumeData.3
            )
        )

        log.debug(
            "disk usage calculation complete",
            metadata: [
                "images_total": "\(imageData.totalCount)",
                "containers_total": "\(containerData.0)",
                "volumes_total": "\(volumeData.0)",
            ])

        return stats
    }
}
