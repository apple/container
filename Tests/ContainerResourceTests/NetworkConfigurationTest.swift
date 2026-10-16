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
import Foundation
import Testing

@testable import ContainerResource

struct NetworkConfigurationTest {
    @Test func testValidationOkDefaults() throws {
        let id = "foo"
        _ = try NetworkConfiguration(
            name: id,
            mode: .nat,
            plugin: "container-network-vmnet"
        )
    }

    @Test func testValidationGoodId() throws {
        let ids = [
            String(repeating: "0", count: 63),
            "0",
            "0-_.1",
        ]
        for id in ids {
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            let labels = try ResourceLabels([
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ])
            _ = try NetworkConfiguration(
                name: id,
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                labels: labels,
                plugin: "container-network-vmnet"
            )
        }
    }

    @Test func testValidationBadId() throws {
        let ids = [
            String(repeating: "0", count: 64),
            "-foo",
            "foo_",
            "Foo",
        ]
        for id in ids {
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            let labels = try ResourceLabels([
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ])
            #expect {
                _ = try NetworkConfiguration(
                    name: id,
                    mode: .nat,
                    ipv4Subnet: ipv4Subnet,
                    labels: labels,
                    plugin: "container-network-vmnet"
                )
            } throws: { error in
                guard let err = error as? ContainerizationError else { return false }
                #expect(err.code == .invalidArgument)
                #expect(err.message.starts(with: "invalid network name"))
                return true
            }
        }
    }

    // MARK: - NetworkConfigurationFile tests

    @Test func testConfigFileDecodeMinimal() throws {
        let json = """
            {"mode": "nat"}
            """
        let data = json.data(using: .utf8)!
        let configFile = try JSONDecoder().decode(NetworkConfigurationFile.self, from: data)
        #expect(configFile.mode == .nat)
        #expect(configFile.ipv4Subnet == nil)
        #expect(configFile.ipv6Subnet == nil)
        #expect(configFile.labels == nil)
        #expect(configFile.plugin == nil)
        #expect(configFile.options == nil)

        let config = try configFile.toNetworkConfiguration(id: "test-net")
        #expect(config.id == "test-net")
        #expect(config.mode == .nat)
        #expect(config.ipv4Subnet == nil)
        #expect(config.ipv6Subnet == nil)
        #expect(config.labels.dictionary == [:])
        #expect(config.plugin == "container-network-vmnet")
        #expect(config.options == [:])
    }

    @Test func testConfigFileDecodeComplete() throws {
        let json = """
            {
                "mode": "hostOnly",
                "ipv4Subnet": "192.168.64.0/24",
                "ipv6Subnet": "fd00::/64",
                "labels": {"env": "production"},
                "plugin": "my-plugin",
                "options": {"variant": "shared"}
            }
            """
        let data = json.data(using: .utf8)!
        let configFile = try JSONDecoder().decode(NetworkConfigurationFile.self, from: data)
        #expect(configFile.mode == .hostOnly)
        #expect(configFile.ipv4Subnet == "192.168.64.0/24")
        #expect(configFile.ipv6Subnet == "fd00::/64")
        #expect(configFile.labels == ["env": "production"])
        #expect(configFile.plugin == "my-plugin")
        #expect(configFile.options?["variant"] == "shared")

        let config = try configFile.toNetworkConfiguration(id: "full-net")
        #expect(config.id == "full-net")
        #expect(config.mode == .hostOnly)
        #expect(config.ipv4Subnet != nil)
        #expect(config.ipv6Subnet != nil)
        #expect(config.labels.dictionary == ["env": "production"])
        #expect(config.plugin == "my-plugin")
        #expect(config.options["variant"] == "shared")
    }

    @Test func testConfigFileInvalidSubnet() throws {
        let json = """
            {"mode": "nat", "ipv4Subnet": "not-a-cidr"}
            """
        let data = json.data(using: .utf8)!
        let configFile = try JSONDecoder().decode(NetworkConfigurationFile.self, from: data)
        #expect(throws: (any Error).self) {
            _ = try configFile.toNetworkConfiguration(id: "test-net")
        }
    }

    @Test func testConfigFileInvalidId() throws {
        let json = """
            {"mode": "nat"}
            """
        let data = json.data(using: .utf8)!
        let configFile = try JSONDecoder().decode(NetworkConfigurationFile.self, from: data)
        #expect {
            _ = try configFile.toNetworkConfiguration(id: "INVALID-ID")
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.code == .invalidArgument)
            #expect(err.message.starts(with: "invalid network name"))
            return true
        }
    }

}
