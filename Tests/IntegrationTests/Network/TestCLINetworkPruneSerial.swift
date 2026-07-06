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

/// Serial tests for `network prune` — pruning affects all unused networks regardless of name.
@Suite(.serialized)
struct TestCLINetworkPruneSerial {

    @available(macOS 26, *)
    @Test func testNetworkPruneNoNetworks() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["network", "prune"]).check()
            #expect(result.output.isEmpty, "should show no networks pruned")
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneUnusedNetworks() async throws {
        try await ContainerFixture.with { f in
            let net1 = "\(f.testID)-net1"
            let net2 = "\(f.testID)-net2"
            f.addCleanup { f.doNetworkDeleteIfExists(net1) }
            f.addCleanup { f.doNetworkDeleteIfExists(net2) }

            try f.doNetworkCreate(net1)
            try f.doNetworkCreate(net2)

            let listBefore = try f.run(["network", "list", "--quiet"]).check().output
            #expect(listBefore.contains(net1))
            #expect(listBefore.contains(net2))

            let result = try f.run(["network", "prune"]).check()
            #expect(result.output.contains(net1), "should prune \(net1)")
            #expect(result.output.contains(net2), "should prune \(net2)")

            let listAfter = try f.run(["network", "list", "--quiet"]).check().output
            #expect(!listAfter.contains(net1), "\(net1) should be pruned")
            #expect(!listAfter.contains(net2), "\(net2) should be pruned")
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneSkipsNetworksInUse() async throws {
        try await ContainerFixture.with { f in
            let containerName = "\(f.testID)-c"
            let netInUse = "\(f.testID)-inuse"
            let netUnused = "\(f.testID)-unused"
            f.addCleanup { f.doNetworkDeleteIfExists(netInUse) }
            f.addCleanup { f.doNetworkDeleteIfExists(netUnused) }
            f.addCleanup {
                try? f.doStop(containerName)
                try? f.doRemove(containerName)
            }

            try f.doNetworkCreate(netInUse)
            try f.doNetworkCreate(netUnused)

            let port = UInt16.random(in: 50000..<60000)
            try f.doLongRun(
                name: containerName,
                image: "docker.io/library/python:alpine",
                args: ["--network", netInUse],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"],
                autoRemove: false)
            try await f.waitForContainerRunning(containerName)
            let container = try f.inspectContainer(containerName)
            #expect(container.networks.count > 0)

            try f.run(["network", "prune"]).check()

            let listAfter = try f.run(["network", "list", "--quiet"]).check().output
            #expect(listAfter.contains(netInUse), "network in use should not be pruned")
            #expect(!listAfter.contains(netUnused), "unused network should be pruned")
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneSkipsNetworkAttachedToStoppedContainer() async throws {
        try await ContainerFixture.with { f in
            let containerName = "\(f.testID)-c"
            let networkName = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(networkName) }
            f.addCleanup {
                try? f.doStop(containerName)
                try? f.doRemove(containerName)
            }

            try f.doNetworkCreate(networkName)

            let port = UInt16.random(in: 50000..<60000)
            try f.doLongRun(
                name: containerName,
                image: "docker.io/library/python:alpine",
                args: ["--network", networkName],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"],
                autoRemove: false)
            try await f.waitForContainerRunning(containerName)

            // Network is attached to a running container — prune must skip it.
            try f.run(["network", "prune"]).check()
            let listMid = try f.run(["network", "list", "--quiet"]).check().output
            #expect(
                listMid.contains(networkName),
                "network attached to running container should not be pruned")

            // Stop and remove the container, then prune again — now it should go.
            try f.doStop(containerName)
            try f.doRemove(containerName)
            try f.run(["network", "prune"]).check()

            let listFinal = try f.run(["network", "list", "--quiet"]).check().output
            #expect(
                !listFinal.contains(networkName),
                "network should be pruned after container is deleted")
        }
    }
}
