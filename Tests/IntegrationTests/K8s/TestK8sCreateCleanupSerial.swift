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
struct TestK8sCreateCleanupSerial {

    /// If a container occupying the control-plane name already exists and isn't owned by
    /// the k8s plugin, `k8s create` must fail (name collision) without deleting it.
    @Test func testFailedCreateDoesNotTeardownUnrelatedControlPlaneNameContainer() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"

            try await f.doLongRun(name: name, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(name)
                try? f.doRemove(name, force: true)
            }
            let preExistingId = try f.getContainerId(name)

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-create-cleanup] k8s create stderr: \(result.error)")
            #expect(result.status != 0)

            // The pre-existing, unrelated container must survive untouched.
            #expect(try f.getContainerId(name) == preExistingId)
        }
    }

    /// If a container occupying a would-be worker name already exists and isn't owned by
    /// the k8s plugin, the control-plane node that *was* legitimately created should be
    /// torn down on failure, but the unrelated worker-named container must be left alone.
    @Test func testFailedCreateDoesNotTeardownUnrelatedWorkerNameContainer() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            let workerName = "\(name)-worker-1"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try await f.doLongRun(name: workerName, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(workerName)
                try? f.doRemove(workerName, force: true)
            }
            let preExistingId = try f.getContainerId(workerName)

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["k8s", "create", "--name", name, "--workers", "1"])
            print("[k8s-create-cleanup] k8s create stderr: \(result.error)")
            #expect(result.status != 0)

            // The unrelated worker-named container must survive untouched.
            #expect(try f.getContainerId(workerName) == preExistingId)

            // The control-plane node this run legitimately created should have been torn down.
            #expect(throws: (any Error).self) { try f.getContainerStatus(name) }
        }
    }
}
