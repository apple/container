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
struct TestClusterMultiNodeSerial {

    @discardableResult
    private func kubectl(_ f: ContainerFixture, node: String, args: [String]) throws -> (output: String, status: Int32) {
        print("[cluster-multi] kubectl \(args.joined(separator: " ")) (node: \(node))")
        let result = try f.run(["exec", node, "kubectl"] + args)
        return (result.output, result.status)
    }

    // "kubectl get nodes --no-headers" lines look like:
    //   <name>   <status>   <roles>   <age>   <version>
    private func nodeRows(_ output: String) -> [(name: String, status: String, roles: String)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3 else { return nil }
            return (name: fields[0], status: fields[1], roles: fields[2])
        }
    }

    @Test func testCreateWithWorkersRegistersAllNodes() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let workerNames = [1, 2].map { "\(name)-worker-\($0)" }
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["cluster", "create", "--name", name, "--workers", "2"])
            if result.status != 0 {
                print("[cluster-multi] cluster create stderr: \(result.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try result.check()
            #expect(result.output.contains(name))

            // Control plane and both worker containers should all be running.
            #expect(try f.getContainerStatus(name) == "running")
            for workerName in workerNames {
                #expect(try f.getContainerStatus(workerName) == "running")
            }

            // The control plane and both workers must be registered and Ready in-cluster.
            let (nodesOutput, nodesStatus) = try kubectl(f, node: name, args: ["get", "nodes", "--no-headers"])
            #expect(nodesStatus == 0)
            let rows = nodeRows(nodesOutput)
            #expect(rows.count == 3)

            let controlPlaneRow = rows.first { $0.name == name }
            #expect(controlPlaneRow != nil)
            #expect(controlPlaneRow?.roles == "control-plane")
            #expect(controlPlaneRow?.status == "Ready")

            for workerName in workerNames {
                let workerRow = rows.first { $0.name == workerName }
                #expect(workerRow != nil)
                #expect(workerRow?.roles == "<none>")
                #expect(workerRow?.status == "Ready")
            }

            // container cluster list should surface every node under the same cluster.
            let listResult = try f.run(["cluster", "list", "--nodes"])
            #expect(listResult.status == 0)
            #expect(listResult.output.contains(name))
            for workerName in workerNames {
                #expect(listResult.output.contains(workerName))
            }
        }
    }

    @Test func testDeleteRemovesAllWorkerContainers() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let workerNames = [1, 2].map { "\(name)-worker-\($0)" }
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let createResult = try f.run(["cluster", "create", "--name", name, "--workers", "2"])
            if createResult.status != 0 {
                print("[cluster-multi] cluster create stderr: \(createResult.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try createResult.check()

            for workerName in workerNames {
                #expect(try f.getContainerStatus(workerName) == "running")
            }

            let deleteResult = try f.run(["cluster", "delete", "--name", name])
            try deleteResult.check()

            // The control plane and every worker container should be gone, not just the
            // control plane — this is exactly what `ClusterDelete`'s worker enumeration covers.
            #expect(throws: (any Error).self) { try f.getContainerStatus(name) }
            for workerName in workerNames {
                #expect(throws: (any Error).self) { try f.getContainerStatus(workerName) }
            }

            let listResult = try f.run(["cluster", "list"])
            #expect(!listResult.output.contains(name))
        }
    }

    private let gib: UInt64 = 1024 * 1024 * 1024

    /// Mixed `--workers` groups size each worker individually, while `--cpus` and `--memory`
    /// size only the control plane. Workers are numbered across groups.
    @Test func testWorkerGroupsAreSizedIndividually() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run([
                "cluster", "create", "--name", name,
                "--cpus", "2", "--memory", "2g",
                "--workers", "count=2,cpus=3,memory=3g",
                "--workers", "count=1,cpus=2,memory=2g",
            ])
            if result.status != 0 {
                print("[cluster-multi] cluster create stderr: \(result.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try result.check()

            let expected: [(node: String, cpus: Int, memory: UInt64)] = [
                (name, 2, 2 * gib),
                ("\(name)-worker-1", 3, 3 * gib),
                ("\(name)-worker-2", 3, 3 * gib),
                ("\(name)-worker-3", 2, 2 * gib),
            ]
            for (node, cpus, memory) in expected {
                let resources = try f.inspectContainer(node).configuration.resources
                #expect(resources.cpus == cpus, "cpus for \(node)")
                #expect(resources.memoryInBytes == memory, "memory for \(node)")
            }
        }
    }

    /// With workers and no resource flags, the control plane gets the fixed smaller default and
    /// workers get the same default as a single-node cluster.
    @Test func testDefaultSizesWithWorkers() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let workerName = "\(name)-worker-1"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["cluster", "create", "--name", name, "--workers", "1"])
            if result.status != 0 {
                print("[cluster-multi] cluster create stderr: \(result.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try result.check()

            let controlPlane = try f.inspectContainer(name).configuration.resources
            #expect(controlPlane.cpus == 2)
            #expect(controlPlane.memoryInBytes == 2 * gib)

            // Single-node default: 1/4 of host CPUs and memory, minimum 2 CPUs and 2g.
            let hostGiB = ProcessInfo.processInfo.physicalMemory / gib
            let worker = try f.inspectContainer(workerName).configuration.resources
            #expect(worker.cpus == max(ProcessInfo.processInfo.processorCount / 4, 2))
            #expect(worker.memoryInBytes == max(hostGiB / 4, 2) * gib)
        }
    }
}
