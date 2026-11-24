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

import ContainerClusterServiceClient
import ContainerResource
import Foundation
import Testing

@testable import ContainerClusterService

@Suite("ClusterService status")
struct ClusterServiceStatusTests {
    @Test func noConfigurationsMeansNoClusters() throws {
        let cp = try makeControlPlane("dev")
        #expect(ClusterService.resources(configurations: [], snapshots: [cp]).isEmpty)
    }

    @Test func allRunningIsRunning() throws {
        let infos = ClusterService.resources(
            configurations: [makeConfig("dev", workers: 1)],
            snapshots: [try makeControlPlane("dev", addr: "10.0.0.1"), try makeWorker("dev-worker-1")])
        #expect(infos[0].status.state == .running)
        #expect(infos[0].status.nodes.map(\.name) == ["dev", "dev-worker-1"])
        #expect(infos[0].status.nodes[0].addresses == ["10.0.0.1"])
        #expect(infos[0].status.nodes[1].addresses == nil)
    }

    @Test func partiallyUpIsDegraded() throws {
        let stopped = try makeSnapshot(id: "dev-worker-1", role: "worker", status: .stopped)
        let infos = ClusterService.resources(
            configurations: [makeConfig("dev", workers: 1)],
            snapshots: [try makeControlPlane("dev"), stopped])
        #expect(infos[0].status.state == .degraded)
        #expect(infos[0].status.nodes.map(\.status) == [.running, .stopped])
    }

    @Test func missingContainersCountAsStopped() {
        let infos = ClusterService.resources(configurations: [makeConfig("dev", workers: 1)], snapshots: [])
        #expect(infos[0].status.state == .stopped)
        #expect(infos[0].status.nodes.allSatisfy { $0.status == .stopped })
    }

    @Test func sortedByNameAndIgnoresOtherClustersContainers() throws {
        let infos = ClusterService.resources(
            configurations: [makeConfig("zebra"), makeConfig("apple")],
            snapshots: [try makeControlPlane("zebra"), try makeControlPlane("unrelated")])
        #expect(infos.map(\.configuration.name) == ["apple", "zebra"])
        #expect(infos[0].status.state == .stopped)
        #expect(infos[1].status.state == .running)
    }
}
