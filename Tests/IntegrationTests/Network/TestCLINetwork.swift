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

import AsyncHTTPClient
import ContainerizationExtras
import Foundation
import Testing

@Suite
struct TestCLINetwork {

    // MARK: - Tests

    @available(macOS 26, *)
    @Test func testNetworkCreateAndUse() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            let c = "\(f.testID)-c"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }

            try f.doNetworkCreate(net)

            let listResult = try f.run(["network", "ls", "--quiet"]).check()
            let networkIds = listResult.output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            #expect(networkIds == networkIds.sorted(), "network IDs should be sorted")

            let port = UInt16.random(in: 50000..<60000)
            try f.doLongRun(
                name: c, image: "docker.io/library/python:alpine",
                args: ["--network", net],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let container = try f.inspectContainer(c)
            #expect(container.networks.count > 0)
            let ip = container.networks[0].ipv4Address.address
            let url = "http://\(ip):\(port)"

            // waitForContainerRunning only tells us init is running; the python http
            // server inside is still starting, so retry until it accepts connections.
            let client = f.makeHTTPClient()
            defer { _ = client.shutdown() }
            try await f.retry(attempts: 10) {
                do {
                    var req = HTTPClientRequest(url: url)
                    req.method = .GET
                    let resp = try await client.execute(req, timeout: .seconds(3))
                    return resp.status.code >= 200 && resp.status.code < 300
                } catch {
                    return false
                }
            }
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkDeleteWithContainer() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            let c = "\(f.testID)-c"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            f.addCleanup { try? f.doRemove(c, force: true) }

            try f.doNetworkCreate(net)
            try f.doCreate(name: c, networks: [net])

            let deleteResult = try f.run(["network", "delete", net])
            try #require(deleteResult.status != 0, "network delete should fail while container references it")
            #expect(deleteResult.error.contains("delete failed"))
            #expect(deleteResult.error.contains("[\"\(net)\"]"))

            try f.doRemove(c, force: true)
            try f.doNetworkDelete(net)
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkLabels() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }

            try f.doNetworkCreate(net, args: ["--label", "foo=bar", "--label", "baz=qux"])

            let network = try f.inspectNetwork(net)
            let expectedLabels = ["foo": "bar", "baz": "qux"]
            #expect(expectedLabels == network.configuration.labels.dictionary)
        }
    }

    @Test func testNetworkMTU() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--network", "default,mtu=1500"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1500"), "expected mtu 1500 in ip link output: \(output)")
        }
    }

    @available(macOS 26, *)
    @Test func testIsolatedNetwork() async {
        await withKnownIssue("curl error 7 despite retries", isIntermittent: true) {
            try await ContainerFixture.with { f in
                let net = "\(f.testID)-net"
                let server = "\(f.testID)-server"
                let pythonImage = "docker.io/library/python:alpine"
                let curlImage = "docker.io/curlimages/curl:8.6.0"

                f.addCleanup { f.doNetworkDeleteIfExists(net) }
                f.addCleanup {
                    try? f.doStop(server)
                    try? f.doRemove(server)
                }

                try f.doNetworkCreate(net, args: ["--internal"])

                let port = UInt16.random(in: 50000..<60000)
                try f.doLongRun(
                    name: server, image: pythonImage,
                    args: ["--network", net],
                    containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"],
                    autoRemove: false)
                try await f.waitForContainerRunning(server)

                let container = try f.inspectContainer(server)
                #expect(container.networks.count > 0)
                let ip = container.networks[0].ipv4Address.address
                let serverURL = "http://\(ip):\(port)"

                // Internal connection should succeed. `waitForContainerRunning` only
                // proves the container's init is up; the python http.server inside
                // may still be starting, so retry until it accepts connections.
                try await f.retry(attempts: 10) {
                    let result = try f.run([
                        "run", "--rm", "--network", net, curlImage,
                        "curl", "--connect-timeout", "3", serverURL,
                    ])
                    return result.status == 0
                }

                // External connection should be blocked — the isolated network has no gateway.
                let externalResult = try f.run([
                    "run", "--rm", "--network", net, curlImage,
                    "curl", "--connect-timeout", "5", "http://google.com",
                ])
                let hostOnlyBlockedCodes: Set<Int32> = [6, 7, 28]
                #expect(
                    hostOnlyBlockedCodes.contains(externalResult.status),
                    "external connection from isolated network should be blocked, got exit \(externalResult.status)")
            }
        }
    }

    @Test func testNetworkListTableFormat() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            try f.doNetworkCreate(net)

            let result = try f.run(["network", "list"]).check()
            #expect(["NETWORK", "SUBNET"].allSatisfy { result.output.contains($0) })
            #expect(result.output.contains(net))
        }
    }

    @Test func testNetworkListJSONFormat() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            try f.doNetworkCreate(net)

            let result = try f.run(["network", "list", "--format", "json"]).check()
            guard let json = try JSONSerialization.jsonObject(with: result.outputData) as? [[String: Any]] else {
                Issue.record("JSON output should be an array of objects")
                return
            }
            #expect(json.contains { ($0["id"] as? String) == net })
        }
    }

    @Test func testInspectMissingNetworkFails() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["network", "inspect", "definitely-missing-\(f.testID)"])
            #expect(result.status != 0)
            #expect(result.error.contains("network not found"))
        }
    }
}
