//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

//

import AsyncHTTPClient
import ContainerClient
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Testing

class TestCLINetwork: CLITest {
    private static let retries = 10
    private static let retryDelaySeconds = Int64(3)

    @available(macOS 26, *)
    @Test func testNetworkCreateAndUse() async throws {
        do {
            let name = Test.current!.name.trimmingCharacters(in: ["(", ")"])
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
            Issue.record("failed to run container \(error)")
            return
        }
    }

    private func getClient() -> HTTPClient {
        var httpConfiguration = HTTPClient.Configuration()
        let proxyConfig: HTTPClient.Configuration.Proxy? = {
            let proxyEnv = ProcessInfo.processInfo.environment["HTTP_PROXY"]
            guard let proxyEnv else {
                return nil
            }
            guard let url = URL(string: proxyEnv), let host = url.host(), let port = url.port else {
                return nil
            }
            return .server(host: host, port: port)
        }()
        httpConfiguration.proxy = proxyConfig
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
    }
}
