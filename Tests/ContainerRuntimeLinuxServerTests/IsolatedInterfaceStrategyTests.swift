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
import Containerization
import ContainerizationExtras
import Testing

@testable import ContainerRuntimeLinuxServer

struct IsolatedInterfaceStrategyTests {
    private static func attachment(mtu: UInt32?) throws -> ContainerResource.Attachment {
        ContainerResource.Attachment(
            network: "default",
            hostname: "foo",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil,
            mtu: mtu
        )
    }

    @Test
    func attachmentWithoutMTUUsesTheGivenDefault() throws {
        let strategy = IsolatedInterfaceStrategy(defaultMTU: 1500)
        let interface = strategy.toInterface(attachment: try Self.attachment(mtu: nil), interfaceIndex: 0, additionalData: nil)
        #expect(interface.mtu == 1500)
    }

    @Test
    func attachmentMTUOverridesTheGivenDefault() throws {
        let strategy = IsolatedInterfaceStrategy(defaultMTU: 1500)
        let interface = strategy.toInterface(attachment: try Self.attachment(mtu: 9000), interfaceIndex: 0, additionalData: nil)
        #expect(interface.mtu == 9000)
    }
}
