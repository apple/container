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
    let defaultNetworkPluginInfo = NetworkPluginInfo(plugin: "container-network-vmnet")

    @Test func testValidationOkDefaults() throws {
        let id = "foo"
        _ = try NetworkConfiguration(
            id: id,
            mode: .nat,
            pluginInfo: defaultNetworkPluginInfo
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
            let labels = [
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ]
            _ = try NetworkConfiguration(
                id: id,
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                labels: labels,
                pluginInfo: defaultNetworkPluginInfo
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
            let labels = [
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ]
            #expect {
                _ = try NetworkConfiguration(
                    id: id,
                    mode: .nat,
                    ipv4Subnet: ipv4Subnet,
                    labels: labels,
                    pluginInfo: defaultNetworkPluginInfo
                )
            } throws: { error in
                guard let err = error as? ContainerizationError else { return false }
                #expect(err.code == .invalidArgument)
                #expect(err.message.starts(with: "invalid network ID"))
                return true
            }
        }
    }

    @Test func testValidationGoodLabels() throws {
        let allLabels = [
            ["com.example.my-label": "bar"],
            ["mycompany.com/my-label": "bar"],
            ["foo": String(repeating: "0", count: 4096 - "foo".count - "=".count)],
            [String(repeating: "0", count: 128): ""],
        ]
        for labels in allLabels {
            let id = "foo"
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            _ = try NetworkConfiguration(
                id: id,
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                labels: labels,
                pluginInfo: defaultNetworkPluginInfo
            )
        }
    }

    @Test func testValidationBadLabels() throws {
        let allLabels = [
            [String(repeating: "0", count: 129): ""],
            ["foo": String(repeating: "0", count: 4097 - "foo".count - "=".count)],
            ["com..example.my-label": "bar"],
            ["mycompany.com//my-label": "bar"],
            ["": String(repeating: "0", count: 4096 - "foo".count - "=".count)],
        ]
        for labels in allLabels {
            let id = "foo"
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            #expect {
                _ = try NetworkConfiguration(
                    id: id,
                    mode: .nat,
                    ipv4Subnet: ipv4Subnet,
                    labels: labels,
                    pluginInfo: defaultNetworkPluginInfo
                )
            } throws: { error in
                guard let err = error as? ContainerizationError else { return false }
                #expect(err.code == .invalidArgument)
                #expect(err.message.starts(with: "invalid label"))
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
        #expect(configFile.pluginInfo == nil)

        let config = try configFile.toNetworkConfiguration(id: "test-net")
        #expect(config.id == "test-net")
        #expect(config.mode == .nat)
        #expect(config.ipv4Subnet == nil)
        #expect(config.ipv6Subnet == nil)
        #expect(config.labels == [:])
        #expect(config.pluginInfo?.plugin == "container-network-vmnet")
    }

    @Test func testConfigFileDecodeComplete() throws {
        let json = """
            {
                "mode": "hostOnly",
                "ipv4Subnet": "192.168.64.0/24",
                "ipv6Subnet": "fd00::/64",
                "labels": {"env": "production"},
                "pluginInfo": {"plugin": "my-plugin", "variant": "shared"}
            }
            """
        let data = json.data(using: .utf8)!
        let configFile = try JSONDecoder().decode(NetworkConfigurationFile.self, from: data)
        #expect(configFile.mode == .hostOnly)
        #expect(configFile.ipv4Subnet == "192.168.64.0/24")
        #expect(configFile.ipv6Subnet == "fd00::/64")
        #expect(configFile.labels == ["env": "production"])
        #expect(configFile.pluginInfo?.plugin == "my-plugin")
        #expect(configFile.pluginInfo?.variant == "shared")

        let config = try configFile.toNetworkConfiguration(id: "full-net")
        #expect(config.id == "full-net")
        #expect(config.mode == .hostOnly)
        #expect(config.ipv4Subnet != nil)
        #expect(config.ipv6Subnet != nil)
        #expect(config.labels == ["env": "production"])
        #expect(config.pluginInfo?.plugin == "my-plugin")
        #expect(config.pluginInfo?.variant == "shared")
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
            #expect(err.message.starts(with: "invalid network ID"))
            return true
        }
    }

}
