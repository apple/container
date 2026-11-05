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

import ContainerTestSupport
import Foundation
import Testing

@Suite(.serialized)
struct TestClusterCreateCleanupSerial {

    /// If a container occupying the control-plane name already exists and isn't owned by
    /// the cluster plugin, `cluster create` must fail (name collision) without deleting it.
    @Test func testFailedCreateDoesNotTeardownUnrelatedControlPlaneNameContainer() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"

            try await f.doLongRun(name: name, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(name)
                try? f.doRemove(name, force: true)
            }
            let preExistingId = try f.getContainerId(name)

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["cluster", "create", "--name", name])
            print("[cluster-create-cleanup] cluster create stderr: \(result.error)")
            #expect(result.status != 0)

            // The pre-existing, unrelated container must survive untouched.
            #expect(try f.getContainerId(name) == preExistingId)
        }
    }

    /// If a container occupying a would-be worker name already exists and isn't owned by
    /// the cluster plugin, the control-plane node that *was* legitimately created should be
    /// torn down on failure, but the unrelated worker-named container must be left alone.
    @Test func testFailedCreateDoesNotTeardownUnrelatedWorkerNameContainer() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let workerName = "\(name)-worker-1"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            try await f.doLongRun(name: workerName, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(workerName)
                try? f.doRemove(workerName, force: true)
            }
            let preExistingId = try f.getContainerId(workerName)

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["cluster", "create", "--name", name, "--workers", "1"])
            print("[cluster-create-cleanup] cluster create stderr: \(result.error)")
            #expect(result.status != 0)

            // The unrelated worker-named container must survive untouched.
            #expect(try f.getContainerId(workerName) == preExistingId)

            // The control-plane node this run legitimately created should have been torn down.
            #expect(throws: (any Error).self) { try f.getContainerStatus(name) }
        }
    }

    /// With `--retain`, a create that fails after `kubeadm init` must leave the control-plane
    /// node running and the cluster recorded, so kubectl works against it and
    /// `cluster delete` can clean it up afterward.
    @Test func testFailedCreateWithRetainKeepsNodes() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let workerName = "\(name)-worker-1"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            // An unrelated container on the worker name makes the worker join fail after the
            // control plane is up.
            try await f.doLongRun(name: workerName, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(workerName)
                try? f.doRemove(workerName, force: true)
            }
            let preExistingId = try f.getContainerId(workerName)

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["cluster", "create", "--name", name, "--workers", "1", "--retain"])
            print("[cluster-create-cleanup] cluster create stderr: \(result.error)")
            #expect(result.status != 0)

            // The control-plane node is retained and kubectl can reach its API server.
            #expect(try f.getContainerStatus(name) == "running")
            let (nodesOutput, nodesStatus) = try f.kubectl(node: name, args: ["get", "nodes", "--no-headers"])
            #expect(nodesStatus == 0)
            #expect(nodesOutput.contains(name))

            let listResult = try f.run(["cluster", "list"])
            #expect(listResult.status == 0)
            #expect(listResult.output.contains(name))

            // `cluster delete` removes the retained node but leaves the unrelated container alone.
            try f.run(["cluster", "delete", "--name", name]).check()
            #expect(throws: (any Error).self) { try f.getContainerStatus(name) }
            #expect(try f.getContainerId(workerName) == preExistingId)
        }
    }

    /// `--retain` with `--rm`: a failed create still leaves the control-plane node running for
    /// inspection, and `--rm` removes it once it stops.
    @Test func testFailedCreateWithRetainAndRmRemovesNodeOnStop() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let workerName = "\(name)-worker-1"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            // An unrelated container on the worker name makes the worker join fail after the
            // control plane is up.
            try await f.doLongRun(name: workerName, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(workerName)
                try? f.doRemove(workerName, force: true)
            }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["cluster", "create", "--name", name, "--workers", "1", "--retain", "--rm"])
            print("[cluster-create-cleanup] cluster create stderr: \(result.error)")
            #expect(result.status != 0)

            // The control-plane node is retained and kubectl can reach its API server.
            #expect(try f.getContainerStatus(name) == "running")
            let (nodesOutput, nodesStatus) = try f.kubectl(node: name, args: ["get", "nodes", "--no-headers"])
            #expect(nodesStatus == 0)
            #expect(nodesOutput.contains(name))

            // Stopping the retained node removes it because of `--rm`. Poll until it is gone.
            try f.doStop(name)
            try await f.retry(attempts: 150, delay: .milliseconds(200)) {
                (try? f.getContainerStatus(name)) == nil
            }

            // The cluster record outlives the node, as with any `--rm` cluster, until `cluster delete`.
            let listResult = try f.run(["cluster", "list"])
            #expect(listResult.status == 0)
            #expect(listResult.output.contains(name))
            try f.run(["cluster", "delete", "--name", name]).check()
            #expect(try !f.run(["cluster", "list"]).output.contains(name))
        }
    }

    /// With `--retain`, a control plane that fails while starting removes itself, but the cluster
    /// record is still kept, and `cluster delete` removes it.
    @Test func testFailedCreateWithRetainBeforeNodeStartsKeepsRecord() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            // Nothing listens on port 1, so the node image pull fails before the node container exists.
            let result = try f.run([
                "cluster", "create", "--name", name, "--retain",
                "--node-image", "localhost:1/kindest/node:v1.35.5",
            ])
            print("[cluster-create-cleanup] cluster create stderr: \(result.error)")
            #expect(result.status != 0)

            #expect(throws: (any Error).self) { try f.getContainerStatus(name) }
            let listResult = try f.run(["cluster", "list"])
            #expect(listResult.status == 0)
            #expect(listResult.output.contains(name))

            try f.run(["cluster", "delete", "--name", name]).check()
            #expect(try !f.run(["cluster", "list"]).output.contains(name))
        }
    }
}
