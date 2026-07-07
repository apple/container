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
import ContainerResource
import Foundation

// MARK: - Network inspect output

struct NetworkInspectOutput: Codable {
    struct Status: Codable {
        let ipv4Subnet: String?
        let ipv4Gateway: String?
        let ipv6Subnet: String?
    }
    let id: String
    let configuration: NetworkConfiguration
    let status: Status
}

// MARK: - Network lifecycle helpers

extension ContainerFixture {

    /// Creates a named network, throwing on failure.
    func doNetworkCreate(_ name: String, args: [String] = []) throws {
        var arguments = ["network", "create"]
        arguments += args
        arguments.append(name)
        try run(arguments).check()
    }

    /// Deletes a named network, throwing on failure.
    func doNetworkDelete(_ name: String) throws {
        try run(["network", "delete", name]).check()
    }

    /// Deletes a named network, silently ignoring errors.
    func doNetworkDeleteIfExists(_ name: String) {
        _ = try? run(["network", "delete", name])
    }

    /// Inspects a network and returns decoded output.
    func inspectNetwork(_ name: String) throws -> NetworkInspectOutput {
        let result = try run(["network", "inspect", name]).check()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let networks = try decoder.decode([NetworkInspectOutput].self, from: result.outputData)
        guard let network = networks.first else {
            throw CommandError.executionFailed("network inspect returned empty array")
        }
        return network
    }

    /// Returns an `HTTPClient` for use in network connectivity tests.
    func makeHTTPClient() -> HTTPClient {
        HTTPClient(eventLoopGroupProvider: .singleton)
    }
}
