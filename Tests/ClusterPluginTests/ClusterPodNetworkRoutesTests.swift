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

import Testing

@testable import ContainerCluster

private let control = ClusterHelper.NodePodNetwork(name: "c1", podCIDR: "10.244.0.0/24", internalIP: "192.168.64.4")
private let worker = ClusterHelper.NodePodNetwork(name: "c1-worker", podCIDR: "10.244.1.0/24", internalIP: "192.168.64.5")

private let controlRoutes = """
    default via 192.168.64.1 dev enp0s1
    10.244.1.0/24 via 192.168.64.5 dev enp0s1
    192.168.64.0/24 dev enp0s1 proto kernel scope link src 192.168.64.4
    """
private let workerRoutes = """
    default via 192.168.64.1 dev enp0s1
    10.244.0.0/24 via 192.168.64.4 dev enp0s1
    192.168.64.0/24 dev enp0s1 proto kernel scope link src 192.168.64.5
    """

@Suite("ClusterHelper.missingPodRoutes")
struct MissingPodRoutesTests {
    @Test func completeRoutesReportNothingMissing() {
        let missing = ClusterHelper.missingPodRoutes(
            nodes: [control, worker], routesByNode: ["c1": controlRoutes, "c1-worker": workerRoutes])
        #expect(missing == [])
    }

    @Test func workerWithoutControlPlaneRouteIsReported() {
        let bare = "default via 192.168.64.1 dev enp0s1\n192.168.64.0/24 dev enp0s1 proto kernel scope link src 192.168.64.5"
        let missing = ClusterHelper.missingPodRoutes(
            nodes: [control, worker], routesByNode: ["c1": controlRoutes, "c1-worker": bare])
        #expect(missing == ["c1-worker has no route to 10.244.0.0/24 via 192.168.64.4"])
    }

    @Test func routeViaStaleGatewayIsReported() {
        let stale = "10.244.0.0/24 via 192.168.64.9 dev enp0s1"
        let missing = ClusterHelper.missingPodRoutes(
            nodes: [control, worker], routesByNode: ["c1": controlRoutes, "c1-worker": stale])
        #expect(missing == ["c1-worker has no route to 10.244.0.0/24 via 192.168.64.4"])
    }

    @Test func singleNodeReportsNothingMissing() {
        let missing = ClusterHelper.missingPodRoutes(nodes: [control], routesByNode: ["c1": ""])
        #expect(missing == [])
    }

    @Test func nodeAbsentFromRoutesIsReportedForEveryOtherNode() {
        let third = ClusterHelper.NodePodNetwork(name: "c1-worker2", podCIDR: "10.244.2.0/24", internalIP: "192.168.64.6")
        let missing = ClusterHelper.missingPodRoutes(
            nodes: [control, worker, third],
            routesByNode: [
                "c1": "10.244.1.0/24 via 192.168.64.5 dev enp0s1\n10.244.2.0/24 via 192.168.64.6 dev enp0s1",
                "c1-worker": "10.244.0.0/24 via 192.168.64.4 dev enp0s1\n10.244.2.0/24 via 192.168.64.6 dev enp0s1",
            ])
        #expect(
            missing == [
                "c1-worker2 has no route to 10.244.0.0/24 via 192.168.64.4",
                "c1-worker2 has no route to 10.244.1.0/24 via 192.168.64.5",
            ])
    }

    @Test func routeLineEndingAfterGatewayCounts() {
        let routes = "10.244.0.0/24 via 192.168.64.4"
        let missing = ClusterHelper.missingPodRoutes(
            nodes: [control, worker], routesByNode: ["c1": controlRoutes, "c1-worker": routes])
        #expect(missing == [])
    }
}

@Suite("ClusterHelper.parseNodePodNetworks")
struct ParseNodePodNetworksTests {
    @Test func parserReadsThreeFieldLinesInOrder() {
        let nodes = ClusterHelper.parseNodePodNetworks("c1 10.244.0.0/24 192.168.64.4\nc1-worker 10.244.1.0/24 192.168.64.5\n")
        #expect(nodes == [control, worker])
    }

    @Test func parserIgnoresBlankAndMalformedLines() {
        let output = "\nc1 10.244.0.0/24 192.168.64.4\n   \nonlytwo fields\ntoo many fields here now\n"
        #expect(ClusterHelper.parseNodePodNetworks(output) == [control])
    }

    @Test func parserDropsLineWithEmptyPodCIDR() {
        #expect(ClusterHelper.parseNodePodNetworks("c1  192.168.64.4\n") == [])
    }
}

@Suite("ClusterHelper.podNetworkProblems")
struct PodNetworkProblemsTests {
    @Test func emptyNodeListWithExpectedCountIsAProblem() {
        let problems = ClusterHelper.podNetworkProblems(nodes: [], expectedNodeCount: 2, routesByNode: [:])
        #expect(problems == ["found 0 of 2 nodes with a pod CIDR and InternalIP"])
    }

    @Test func matchingCountWithCompleteRoutesHasNoProblems() {
        let problems = ClusterHelper.podNetworkProblems(
            nodes: [control, worker], expectedNodeCount: 2,
            routesByNode: ["c1": controlRoutes, "c1-worker": workerRoutes])
        #expect(problems == [])
    }

    @Test func matchingCountWithMissingRouteReportsTheRoute() {
        let problems = ClusterHelper.podNetworkProblems(
            nodes: [control, worker], expectedNodeCount: 2, routesByNode: ["c1": controlRoutes, "c1-worker": ""])
        #expect(problems == ["c1-worker has no route to 10.244.0.0/24 via 192.168.64.4"])
    }

    @Test func countMismatchTakesPriorityOverRouteChecks() {
        let problems = ClusterHelper.podNetworkProblems(
            nodes: [control, worker], expectedNodeCount: 3, routesByNode: ["c1": controlRoutes, "c1-worker": workerRoutes])
        #expect(problems == ["found 2 of 3 nodes with a pod CIDR and InternalIP"])
    }
}
