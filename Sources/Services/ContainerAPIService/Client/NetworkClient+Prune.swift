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

extension NetworkClient {
    /// Remove networks with no container connections, returning the outcome.
    public func prune() async throws -> PruneResult {
        let client = ContainerClient()
        let allContainers = try await client.list()
        let allNetworks = try await list()

        var networksInUse = Set<String>()
        for container in allContainers {
            for network in container.configuration.networks {
                networksInUse.insert(network.network)
            }
        }

        let networksToPrune = allNetworks.filter { network in
            !network.isBuiltin && !networksInUse.contains(network.id)
        }

        var prunedNetworks = [String]()
        var failed = [PruneResult.Failure]()

        for network in networksToPrune {
            do {
                try await delete(id: network.id)
                prunedNetworks.append(network.id)
            } catch {
                // Note: This failure may occur due to a race condition between the network/
                // container collection above and a container run command that attaches to a
                // network listed in the networksToPrune collection.
                failed.append(PruneResult.Failure(id: network.id, error: error))
            }
        }

        return PruneResult(pruned: prunedNetworks, failed: failed, reclaimedBytes: 0)
    }
}
