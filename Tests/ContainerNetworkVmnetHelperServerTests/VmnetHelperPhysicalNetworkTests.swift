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
import ContainerizationExtras
import Testing

@testable import ContainerNetworkVmnetHelperServer

struct VmnetHelperPhysicalNetworkTests {
    private func makeConfig(
        subnet: String = "192.168.1.0/24",
        gateway: String = "192.168.1.1",
        pool: ClosedRange<UInt32>? = nil
    ) throws -> VmnetHelperPhysicalNetwork.Configuration {
        try .init(
            id: "test",
            ipv4Subnet: try CIDRv4(subnet),
            ipv4Gateway: try IPv4Address(gateway),
            hostInterface: "en0",
            pool: pool,
            helperPath: nil
        )
    }

    @Test func acceptsValidConfiguration() throws {
        let config = try makeConfig()
        #expect(config.ipv4Gateway == (try IPv4Address("192.168.1.1")))
        #expect(config.hostInterface == "en0")
        #expect(config.pool == nil)
    }

    @Test func acceptsPoolWithinSubnet() throws {
        let lower = try IPv4Address("192.168.1.100").value
        let upper = try IPv4Address("192.168.1.120").value
        let config = try makeConfig(pool: lower...upper)
        #expect(config.pool == lower...upper)
    }

    @Test func rejectsGatewayOutsideSubnet() {
        #expect(throws: ContainerizationError.self) {
            _ = try makeConfig(gateway: "10.0.0.1")
        }
    }

    @Test func rejectsGatewayAtNetworkAddress() {
        #expect(throws: ContainerizationError.self) {
            _ = try makeConfig(gateway: "192.168.1.0")
        }
    }

    @Test func rejectsGatewayAtBroadcastAddress() {
        #expect(throws: ContainerizationError.self) {
            _ = try makeConfig(gateway: "192.168.1.255")
        }
    }

    @Test func rejectsPoolOutsideSubnet() {
        #expect(throws: ContainerizationError.self) {
            let lower = try IPv4Address("10.0.0.1").value
            let upper = try IPv4Address("10.0.0.9").value
            _ = try makeConfig(pool: lower...upper)
        }
    }

    // In a /31 every address is a host address, so the network/broadcast
    // exclusion does not apply to the gateway.
    @Test func allowsBoundaryGatewayInSlash31() throws {
        let config = try makeConfig(subnet: "192.168.1.0/31", gateway: "192.168.1.0")
        #expect(config.ipv4Gateway == (try IPv4Address("192.168.1.0")))
    }
}
