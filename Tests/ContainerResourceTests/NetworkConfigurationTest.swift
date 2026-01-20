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

@testable import ContainerResource

struct NetworkConfigurationTest {
    @Test func testValidationOkDefaults() throws {
        let id = "foo"
        _ = try NetworkConfiguration(id: id, mode: .nat)
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
            _ = try NetworkConfiguration(id: id, mode: .nat, ipv4Subnet: ipv4Subnet, labels: labels)
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
                _ = try NetworkConfiguration(id: id, mode: .nat, ipv4Subnet: ipv4Subnet, labels: labels)
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
            _ = try NetworkConfiguration(id: id, mode: .nat, ipv4Subnet: ipv4Subnet, labels: labels)
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
                _ = try NetworkConfiguration(id: id, mode: .nat, ipv4Subnet: ipv4Subnet, labels: labels)
            } throws: { error in
                guard let err = error as? ContainerizationError else { return false }
                #expect(err.code == .invalidArgument)
                #expect(err.message.starts(with: "invalid label"))
                return true
            }
        }
    }

}
