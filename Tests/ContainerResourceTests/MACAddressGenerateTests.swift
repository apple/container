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

import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerResource

struct MACAddressGenerateTests {
    // The generator fixes the locally-administered and unicast bits, leaving f2/f6/fa/fe.
    @Test(arguments: 0..<64)
    func generatedIsLocallyAdministeredUnicast(_: Int) {
        let firstOctet = UInt8((MACAddress.generate().value >> 40) & 0xff)
        #expect(firstOctet & 0x02 != 0, "locally administered bit must be set")
        #expect(firstOctet & 0x01 == 0, "must be unicast, not multicast")
        #expect([0xf2, 0xf6, 0xfa, 0xfe].contains(firstOctet))
    }

    @Test func attachmentOptionsRoundTripsMACAndAddress() throws {
        let mac = MACAddress.generate()
        let options = AttachmentOptions(
            hostname: "sticky.test.",
            macAddress: mac,
            mtu: 1280,
            ipv4Address: try IPv4Address("192.168.64.3")
        )
        let decoded = try JSONDecoder().decode(
            AttachmentOptions.self,
            from: try JSONEncoder().encode(options)
        )
        #expect(decoded.macAddress == mac)
        #expect(decoded.ipv4Address == options.ipv4Address)
    }

    @Test func attachmentOptionsDecodesLegacyConfigWithoutMAC() throws {
        let legacy = #"{"hostname":"old.test.","mtu":1280}"#
        let decoded = try JSONDecoder().decode(
            AttachmentOptions.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.macAddress == nil)
        #expect(decoded.ipv4Address == nil)
        #expect(decoded.hostname == "old.test.")
    }
}
