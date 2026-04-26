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

extension ContainerClient {
    /// Prune the container
    public func prune() async throws -> PruneResult {
        let containersToPrune = try await list().filter { $0.status == .stopped }
        var prunedContainerIds = [String]()
        var failed = [PruneResult.Failure]()
        var totalSize: UInt64 = 0

        for container in containersToPrune {
            do {
                let actualSize = try await diskUsage(id: container.id)
                totalSize += actualSize
                try await delete(id: container.id)
                prunedContainerIds.append(container.id)
            } catch {
                failed.append(PruneResult.Failure(id: container.id, error: error))
            }
        }

        return PruneResult(pruned: prunedContainerIds, failed: failed, reclaimedBytes: totalSize)
    }
}
