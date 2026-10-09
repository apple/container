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

@testable import ContainerK8s

// MARK: - K8sLoadImage flag parsing

@Suite("K8sLoadImage --node flag")
struct K8sLoadImageNodeFlagTests {
    @Test func nodeDefaultsToEmptyWhenNotProvided() throws {
        let command = try K8sLoadImage.parse(["my-app:latest"])
        #expect(command.node.isEmpty)
    }

    @Test func nodeCapturesProvidedValue() throws {
        let command = try K8sLoadImage.parse(["--node", "k8s-dev-worker-1", "my-app:latest"])
        #expect(command.node == ["k8s-dev-worker-1"])
    }

    @Test func nodeCapturesMultipleProvidedValues() throws {
        let command = try K8sLoadImage.parse([
            "--node", "k8s-dev-worker-1", "--node", "k8s-dev-worker-2", "my-app:latest",
        ])
        #expect(command.node == ["k8s-dev-worker-1", "k8s-dev-worker-2"])
    }
}

// MARK: - K8sLoadImage.resolveTargets

@Suite("K8sLoadImage.resolveTargets")
struct ResolveTargetsTests {
    @Test func noNodesReturnsControlPlaneAndAllWorkers() throws {
        let targets = try K8sLoadImage.resolveTargets(
            clusterName: "k8s-dev", nodes: [], workers: ["k8s-dev-worker-1", "k8s-dev-worker-2"])
        #expect(targets == ["k8s-dev", "k8s-dev-worker-1", "k8s-dev-worker-2"])
    }

    @Test func noNodesWithNoWorkersReturnsOnlyControlPlane() throws {
        let targets = try K8sLoadImage.resolveTargets(clusterName: "k8s-dev", nodes: [], workers: [])
        #expect(targets == ["k8s-dev"])
    }

    @Test func nodeMatchingControlPlaneReturnsJustControlPlane() throws {
        let targets = try K8sLoadImage.resolveTargets(
            clusterName: "k8s-dev", nodes: ["k8s-dev"], workers: ["k8s-dev-worker-1"])
        #expect(targets == ["k8s-dev"])
    }

    @Test func nodeMatchingWorkerReturnsJustThatWorker() throws {
        let targets = try K8sLoadImage.resolveTargets(
            clusterName: "k8s-dev", nodes: ["k8s-dev-worker-2"], workers: ["k8s-dev-worker-1", "k8s-dev-worker-2"])
        #expect(targets == ["k8s-dev-worker-2"])
    }

    @Test func multipleNodesReturnsEachInOrder() throws {
        let targets = try K8sLoadImage.resolveTargets(
            clusterName: "k8s-dev", nodes: ["k8s-dev-worker-2", "k8s-dev"],
            workers: ["k8s-dev-worker-1", "k8s-dev-worker-2"])
        #expect(targets == ["k8s-dev-worker-2", "k8s-dev"])
    }

    @Test func duplicateNodesAreDeduplicated() throws {
        let targets = try K8sLoadImage.resolveTargets(
            clusterName: "k8s-dev", nodes: ["k8s-dev-worker-1", "k8s-dev-worker-1"],
            workers: ["k8s-dev-worker-1"])
        #expect(targets == ["k8s-dev-worker-1"])
    }

    @Test func unknownNodeThrowsInvalidArgument() throws {
        #expect(throws: ContainerizationError.self) {
            try K8sLoadImage.resolveTargets(
                clusterName: "k8s-dev", nodes: ["not-a-node"], workers: ["k8s-dev-worker-1"])
        }
    }
}
