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

class TestCLINetwork: CLITest {
    private static let retries = 10
    private static let retryDelaySeconds = Int64(3)

    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    private func getLowercasedTestName() -> String {
        getTestName().lowercased()
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
}
