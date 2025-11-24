//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import AsyncHTTPClient
import ContainerClient
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Testing

@Suite(.serialized)
class TestCLINetwork: CLITest {
    private static let retries = 10
    private static let retryDelaySeconds = Int64(3)

    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    private func getLowercasedTestName() -> String {
        getTestName().lowercased()
    }

    func doNetworkCreate(name: String) throws {
        let (_, _, error, status) = try run(arguments: ["network", "create", name])
        if status != 0 {
            throw CLIError.executionFailed("network create failed: \(error)")
        }
    }

    func doNetworkDeleteIfExists(name: String) {
        let (_, _, _, _) = (try? run(arguments: ["network", "rm", name])) ?? (nil, "", "", 1)
    }

    @available(macOS 26, *)
    @Test func testNetworkCreateAndUse() async throws {
        do {
            let name = getLowercasedTestName()
            let networkDeleteArgs = ["network", "delete", name]
            _ = try? run(arguments: networkDeleteArgs)

            let networkCreateArgs = ["network", "create", name]
            let result = try run(arguments: networkCreateArgs)
            if result.status != 0 {
                throw CLIError.executionFailed("command failed: \(result.error)")
            }
            defer {
                _ = try? run(arguments: networkDeleteArgs)
            }
            let port = UInt16.random(in: 50000..<60000)
            try doLongRun(
                name: name,
                image: "docker.io/library/python:alpine",
                args: ["--network", name],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"])
            defer {
                try? doStop(name: name)
            }

            let container = try inspectContainer(name)
            #expect(container.networks.count > 0)
            let cidrAddress = try CIDRAddress(container.networks[0].address)
            let url = "http://\(cidrAddress.address):\(port)"
            var request = HTTPClientRequest(url: url)
            request.method = .GET
            let client = getClient()
            defer { _ = client.shutdown() }
            var retriesRemaining = Self.retries
            var success = false
            while !success && retriesRemaining > 0 {
                do {
                    let response = try await client.execute(request, timeout: .seconds(Self.retryDelaySeconds))
                    try #require(response.status == .ok)
                    success = true
                } catch {
                    print("request to \(url) failed, error \(error)")
                    try await Task.sleep(for: .seconds(Self.retryDelaySeconds))
                }
                retriesRemaining -= 1
            }
            #expect(success, "Request to \(url) failed after \(Self.retries - retriesRemaining) retries")
            try doStop(name: name)
        } catch {
            Issue.record("failed to create and use network \(error)")
            return
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkDeleteWithContainer() async throws {
        do {
            // prep: delete container and network, ignoring if it doesn't exist
            let name = getLowercasedTestName()
            try? doRemove(name: name)
            let networkDeleteArgs = ["network", "delete", name]
            _ = try? run(arguments: networkDeleteArgs)

            // create our network
            let networkCreateArgs = ["network", "create", name]
            let networkCreateResult = try run(arguments: networkCreateArgs)
            if networkCreateResult.status != 0 {
                throw CLIError.executionFailed("command failed: \(networkCreateResult.error)")
            }

            // ensure it's deleted
            defer {
                _ = try? run(arguments: networkDeleteArgs)
            }

            // create a container that refers to the network
            try doCreate(name: name, networks: [name])
            defer {
                try? doRemove(name: name)
            }

            // deleting the network should fail
            let networkDeleteResult = try run(arguments: networkDeleteArgs)
            try #require(networkDeleteResult.status != 0)

            // and should fail with a certain message
            let msg = networkDeleteResult.error
            #expect(msg.contains("delete failed"))
            #expect(msg.contains("[\"\(name)\"]"))

            // now get rid of the container and its network reference
            try? doRemove(name: name)

            // delete should succeed
            _ = try run(arguments: networkDeleteArgs)
        } catch {
            Issue.record("failed to safely delete network \(error)")
            return
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkLabels() async throws {
        do {
            // prep: delete container and network, ignoring if it doesn't exist
            let name = getLowercasedTestName()
            try? doRemove(name: name)
            let networkDeleteArgs = ["network", "delete", name]
            _ = try? run(arguments: networkDeleteArgs)

            // create our network
            let networkCreateArgs = ["network", "create", "--label", "foo=bar", "--label", "baz=qux", name]
            let networkCreateResult = try run(arguments: networkCreateArgs)
            guard networkCreateResult.status == 0 else {
                throw CLIError.executionFailed("command failed: \(networkCreateResult.error)")
            }

            // ensure it's deleted
            defer {
                _ = try? run(arguments: networkDeleteArgs)
            }

            // inspect the network
            let networkInspectArgs = ["network", "inspect", name]
            let networkInspectResult = try run(arguments: networkInspectArgs)
            guard networkInspectResult.status == 0 else {
                throw CLIError.executionFailed("command failed: \(networkInspectResult.error)")
            }

            // decode the JSON result
            let networkInspectOutput = networkInspectResult.output
            guard let jsonData = networkInspectOutput.data(using: .utf8) else {
                throw CLIError.invalidOutput("network inspect output invalid")
            }

            let decoder = JSONDecoder()
            let networks = try decoder.decode([NetworkInspectOutput].self, from: jsonData)
            guard networks.count == 1 else {
                throw CLIError.invalidOutput("expected exactly one network from inspect, got \(networks.count)")
            }

            // validate labels

            let expectedLabels = [
                "foo": "bar",
                "baz": "qux",
            ]
            #expect(expectedLabels == networks[0].config.labels)

            // delete should succeed
            _ = try run(arguments: networkDeleteArgs)
        } catch {
            Issue.record("failed to safely delete network \(error)")
            return
        }
    }

    @Test func testNetworkPruneNoNetworks() throws {
        // Ensure the testnetworkcreateanduse network is deleted
        // Clean up is necessary for testing prune with no networks
        doNetworkDeleteIfExists(name: "testnetworkcreateanduse")

        // Prune with no networks should succeed
        let (_, _, _, statusBefore) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusBefore == 0)
        let (_, output, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        #expect(output.isEmpty, "should show no networks pruned")
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneRemovesUnusedNetwork() async throws {
        do {
            let name = getLowercasedTestName()
            doNetworkDeleteIfExists(name: name)

            try doNetworkCreate(name: name)
            try waitForNetworkRunning(name)

            let pruneResult = try run(arguments: ["network", "prune"])
            guard pruneResult.status == 0 else {
                throw CLIError.executionFailed("command failed: \(pruneResult.error)")
            }

            let prunedNetworks = pruneResult.output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            #expect(prunedNetworks.contains(name))

            let inspectResult = try run(arguments: ["network", "inspect", name])
            guard let data = inspectResult.output.data(using: .utf8) else {
                throw CLIError.invalidOutput("network inspect output invalid")
            }
            let decoder = JSONDecoder()
            let networks = try decoder.decode([NetworkInspectOutput].self, from: data)
            #expect(networks.isEmpty)
        } catch {
            Issue.record("failed to prune unused network \(error)")
            return
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneUnusedNetworks() throws {
        let name = getTestName()
        let network1 = "\(name)_1"
        let network2 = "\(name)_2"

        // Clean up any existing resources from previous runs
        doNetworkDeleteIfExists(name: network1)
        doNetworkDeleteIfExists(name: network2)

        defer {
            doNetworkDeleteIfExists(name: network1)
            doNetworkDeleteIfExists(name: network2)
        }

        try doNetworkCreate(name: network1)
        try doNetworkCreate(name: network2)

        // Verify networks are created
        let (_, listBefore, _, statusBefore) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusBefore == 0)
        #expect(listBefore.contains(network1))
        #expect(listBefore.contains(network2))

        // Prune should remove both
        let (_, output, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        #expect(output.contains(network1), "should prune network1")
        #expect(output.contains(network2), "should prune network2")

        // Verify networks are gone
        let (_, listAfter, _, statusAfter) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(!listAfter.contains(network1), "network1 should be pruned")
        #expect(!listAfter.contains(network2), "network2 should be pruned")
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneSkipsNetworksInUse() throws {
        let name = getTestName()
        let containerName = "\(name)_c1"
        let networkInUse = "\(name)_inuse"
        let networkUnused = "\(name)_unused"

        // Clean up any existing resources from previous runs
        try? doStop(name: containerName)
        try? doRemove(name: containerName)
        doNetworkDeleteIfExists(name: networkInUse)
        doNetworkDeleteIfExists(name: networkUnused)

        defer {
            try? doStop(name: containerName)
            try? doRemove(name: containerName)
            doNetworkDeleteIfExists(name: networkInUse)
            doNetworkDeleteIfExists(name: networkUnused)
        }

        try doNetworkCreate(name: networkInUse)
        try doNetworkCreate(name: networkUnused)

        // Verify networks are created
        let (_, listBefore, _, statusBefore) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusBefore == 0)
        #expect(listBefore.contains(networkInUse))
        #expect(listBefore.contains(networkUnused))

        // Creation of container with network connection
        let port = UInt16.random(in: 50000..<60000)
        try doLongRun(
            name: containerName,
            image: "docker.io/library/python:alpine",
            args: ["--network", networkInUse],
            containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"]
        )
        try waitForContainerRunning(containerName)
        let container = try inspectContainer(containerName)
        #expect(container.networks.count > 0)

        // Prune should only remove the unused network
        let (_, _, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        // Verify in-use network still exists
        let (_, listAfter, _, statusAfter) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(listAfter.contains(networkInUse), "network in use should NOT be pruned")
        #expect(!listAfter.contains(networkUnused), "unused network should be pruned")
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneSkipsNetworkAttachedToStoppedContainer() async throws {
        let name = getTestName()
        let containerName = "\(name)_c1"
        let networkName = "\(name)"

        // Clean up any existing resources from previous runs
        try? doStop(name: containerName)
        try? doRemove(name: containerName)
        doNetworkDeleteIfExists(name: networkName)

        defer {
            try? doStop(name: containerName)
            try? doRemove(name: containerName)
            doNetworkDeleteIfExists(name: networkName)
        }

        try doNetworkCreate(name: networkName)

        // Creation of container with network connection
        let port = UInt16.random(in: 50000..<60000)
        try doLongRun(
            name: containerName,
            image: "docker.io/library/python:alpine",
            args: ["--network", networkName],
            containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"]
        )
        try await Task.sleep(for: .seconds(1))

        // Prune should NOT remove the network (container exists, even if stopped)
        let (_, _, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        let (_, listAfter, _, statusAfter) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(listAfter.contains(networkName), "network attached to stopped container should NOT be pruned")

        try? doStop(name: containerName)
        try? doRemove(name: containerName)

        let (_, _, error2, status2) = try run(arguments: ["network", "prune"])
        if status2 != 0 {
            throw CLIError.executionFailed("network prune failed: \(error2)")
        }

        // Verify network is gone
        let (_, listFinal, _, statusFinal) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusFinal == 0)
        #expect(!listFinal.contains(networkName), "network should be pruned after container is deleted")
    }
}
