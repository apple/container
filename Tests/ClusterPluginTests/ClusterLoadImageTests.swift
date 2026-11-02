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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerCluster

// MARK: - ClusterLoadImage flag parsing

@Suite("ClusterLoadImage --node flag")
struct ClusterLoadImageNodeFlagTests {
    @Test func nodeDefaultsToEmptyWhenNotProvided() throws {
        let command = try ClusterLoadImage.parse(["my-app:latest"])
        #expect(command.node.isEmpty)
    }

    @Test func nodeCapturesProvidedValue() throws {
        let command = try ClusterLoadImage.parse(["--node", "cluster-dev-worker-1", "my-app:latest"])
        #expect(command.node == ["cluster-dev-worker-1"])
    }

    @Test func nodeCapturesMultipleProvidedValues() throws {
        let command = try ClusterLoadImage.parse([
            "--node", "cluster-dev-worker-1", "--node", "cluster-dev-worker-2", "my-app:latest",
        ])
        #expect(command.node == ["cluster-dev-worker-1", "cluster-dev-worker-2"])
    }
}

// MARK: - ClusterLoadImage.resolveTargets

@Suite("ClusterLoadImage.resolveTargets")
struct ResolveTargetsTests {
    @Test func noNodesReturnsControlPlaneAndAllWorkers() throws {
        let targets = try ClusterLoadImage.resolveTargets(
            clusterName: "cluster-dev", nodes: [], workers: ["cluster-dev-worker-1", "cluster-dev-worker-2"])
        #expect(targets == ["cluster-dev", "cluster-dev-worker-1", "cluster-dev-worker-2"])
    }

    @Test func noNodesWithNoWorkersReturnsOnlyControlPlane() throws {
        let targets = try ClusterLoadImage.resolveTargets(clusterName: "cluster-dev", nodes: [], workers: [])
        #expect(targets == ["cluster-dev"])
    }

    @Test func nodeMatchingControlPlaneReturnsJustControlPlane() throws {
        let targets = try ClusterLoadImage.resolveTargets(
            clusterName: "cluster-dev", nodes: ["cluster-dev"], workers: ["cluster-dev-worker-1"])
        #expect(targets == ["cluster-dev"])
    }

    @Test func nodeMatchingWorkerReturnsJustThatWorker() throws {
        let targets = try ClusterLoadImage.resolveTargets(
            clusterName: "cluster-dev", nodes: ["cluster-dev-worker-2"], workers: ["cluster-dev-worker-1", "cluster-dev-worker-2"])
        #expect(targets == ["cluster-dev-worker-2"])
    }

    @Test func multipleNodesReturnsEachInOrder() throws {
        let targets = try ClusterLoadImage.resolveTargets(
            clusterName: "cluster-dev", nodes: ["cluster-dev-worker-2", "cluster-dev"],
            workers: ["cluster-dev-worker-1", "cluster-dev-worker-2"])
        #expect(targets == ["cluster-dev-worker-2", "cluster-dev"])
    }

    @Test func duplicateNodesAreDeduplicated() throws {
        let targets = try ClusterLoadImage.resolveTargets(
            clusterName: "cluster-dev", nodes: ["cluster-dev-worker-1", "cluster-dev-worker-1"],
            workers: ["cluster-dev-worker-1"])
        #expect(targets == ["cluster-dev-worker-1"])
    }

    @Test func unknownNodeThrowsInvalidArgument() throws {
        #expect(throws: ContainerizationError.self) {
            try ClusterLoadImage.resolveTargets(
                clusterName: "cluster-dev", nodes: ["not-a-node"], workers: ["cluster-dev-worker-1"])
        }
    }
}
