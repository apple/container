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

import ContainerResource
import Foundation
import Testing

@testable import ContainerCommands

struct NetworkCreateMTUTests {
    @Test
    func mtuDefaultsToNil() throws {
        let command = try Application.NetworkCreate.parse(["foo"])
        #expect(command.mtu == nil)
    }

    @Test
    func mtuIsParsed() throws {
        let command = try Application.NetworkCreate.parse(["--mtu", "1500", "foo"])
        #expect(command.mtu == 1500)
    }

    @Test
    func mtuOutsideTheValidRangeIsRejected() {
        let invalid = [String(NetworkMTU.validRange.lowerBound - 1), String(NetworkMTU.validRange.upperBound + 1), "abc"]
        for value in invalid {
            #expect(throws: (any Error).self, "expected \(value) to be rejected") {
                _ = try Application.NetworkCreate.parse(["--mtu", value, "foo"])
            }
        }
    }
}

struct InspectedNetworkTests {
    private static func network(mtu: UInt32?) throws -> NetworkResource {
        let mtuField = mtu.map { #", "mtu": \#($0)"# } ?? ""
        let json = """
            {
                "id": "foo",
                "configuration": {"name": "foo", "mode": "nat", "plugin": "container-network-vmnet"\(mtuField)},
                "status": {"ipv4Subnet": "192.168.64.0/24", "ipv4Gateway": "192.168.64.1"}
            }
            """
        return try JSONDecoder().decode(NetworkResource.self, from: Data(json.utf8))
    }

    private static func encoded(_ inspected: InspectedNetwork) throws -> [String: Any] {
        let output = try JSONEncoder().encode(inspected)
        return try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    @Test
    func aNetworkMTUIsTheEffectiveMTU() throws {
        let object = try Self.encoded(InspectedNetwork(network: Self.network(mtu: 1400), defaultMTU: 1500))
        #expect(object["effectiveMTU"] as? Int == 1400)
    }

    @Test
    func aNetworkWithoutAnMTUUsesTheDefault() throws {
        let object = try Self.encoded(InspectedNetwork(network: Self.network(mtu: nil), defaultMTU: 1500))
        #expect(object["effectiveMTU"] as? Int == 1500)
    }

    @Test
    func theNetworkFieldsAreStillEncoded() throws {
        let object = try Self.encoded(InspectedNetwork(network: Self.network(mtu: 1400), defaultMTU: 1500))
        #expect(object["id"] as? String == "foo")
        #expect(object["status"] != nil)
        let configuration = try #require(object["configuration"] as? [String: Any])
        #expect(configuration["mtu"] as? Int == 1400)
    }
}
