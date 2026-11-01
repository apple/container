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

extension ClientVolume {
    /// Remove volumes with no container references, returning the outcome.
    public static func prune() async throws -> PruneResult {
        let allVolumes = try await list()

        // Find all volumes not used by any container.
        let client = ContainerClient()
        let containers = try await client.list()
        var volumesInUse = Set<String>()
        for container in containers {
            for mount in container.configuration.mounts {
                if mount.isVolume, let volumeName = mount.volumeName {
                    volumesInUse.insert(volumeName)
                }
            }
        }

        let volumesToPrune = allVolumes.filter { volume in
            !volumesInUse.contains(volume.name)
        }

        var prunedVolumes = [String]()
        var failed = [PruneResult.Failure]()
        var totalSize: UInt64 = 0

        for volume in volumesToPrune {
            do {
                let actualSize = try await volumeDiskUsage(name: volume.name)
                totalSize += actualSize
                try await delete(name: volume.name)
                prunedVolumes.append(volume.name)
            } catch {
                failed.append(PruneResult.Failure(id: volume.name, error: error))
            }
        }

        return PruneResult(pruned: prunedVolumes, failed: failed, reclaimedBytes: totalSize)
    }
}
