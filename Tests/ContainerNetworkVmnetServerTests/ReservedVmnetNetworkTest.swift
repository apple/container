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

import Darwin
import Testing

@testable import ContainerNetworkVmnetServer

struct ReservedVmnetNetworkTest {
    @Test
    func selectsPrimaryActivePointToPointIPv4TunnelInterface() {
        let addresses: [VmnetInterfaceAddress] = [
            .init(name: "en0", flags: activeFlags, family: AF_INET, ip: "192.0.2.10"),
            .init(name: "utun8", flags: activePointToPointFlags, family: AF_INET, ip: "10.153.0.2"),
        ]

        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun8", in: addresses) == "utun8")
    }

    @Test
    func ignoresNonPrimaryTunnelInterfaces() {
        let addresses: [VmnetInterfaceAddress] = [
            .init(name: "en0", flags: activeFlags, family: AF_INET, ip: "192.0.2.10"),
            .init(name: "utun8", flags: activePointToPointFlags, family: AF_INET, ip: "10.153.0.2"),
        ]

        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "en0", in: addresses) == nil)
    }

    @Test
    func ignoresInactiveNonRunningAndNonTunnelInterfaces() {
        let addresses: [VmnetInterfaceAddress] = [
            .init(name: "utun1", flags: UInt32(IFF_POINTOPOINT), family: AF_INET, ip: "10.0.0.2"),
            .init(name: "utun2", flags: UInt32(IFF_UP) | UInt32(IFF_POINTOPOINT), family: AF_INET, ip: "10.0.1.2"),
            .init(name: "en0", flags: activePointToPointFlags, family: AF_INET, ip: "192.0.2.10"),
        ]

        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun1", in: addresses) == nil)
        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun2", in: addresses) == nil)
        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "en0", in: addresses) == nil)
    }

    @Test
    func ignoresIPv6OnlyAndLoopbackEntries() {
        let addresses: [VmnetInterfaceAddress] = [
            .init(name: "utun1", flags: activePointToPointFlags, family: AF_INET6, ip: "fd00::2"),
            .init(name: "utun2", flags: activePointToPointFlags, family: AF_INET, ip: "127.0.0.1"),
        ]

        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun1", in: addresses) == nil)
        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun2", in: addresses) == nil)
    }

    @Test
    func acceptsCommonPointToPointTunnelPrefixes() {
        for name in ["utun8", "tun0", "tap0", "ppp0"] {
            let addresses: [VmnetInterfaceAddress] = [
                .init(name: name, flags: activePointToPointFlags, family: AF_INET, ip: "10.153.0.2")
            ]

            #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: name, in: addresses) == name)
        }
    }

    @Test
    func usesPrimaryInterfaceInsteadOfSortingMultipleTunnels() {
        let addresses: [VmnetInterfaceAddress] = [
            .init(name: "utun8", flags: activePointToPointFlags, family: AF_INET, ip: "10.153.0.2"),
            .init(name: "utun3", flags: activePointToPointFlags, family: AF_INET, ip: "10.154.0.2"),
        ]

        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun8", in: addresses) == "utun8")
        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun3", in: addresses) == "utun3")
    }

    @Test
    func ignoresMissingPrimaryInterface() {
        let addresses: [VmnetInterfaceAddress] = [
            .init(name: "utun8", flags: activePointToPointFlags, family: AF_INET, ip: "10.153.0.2")
        ]

        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: nil, in: addresses) == nil)
        #expect(VmnetExternalInterfaceSelector.activePointToPointIPv4Interface(primaryInterface: "utun3", in: addresses) == nil)
    }

    private var activeFlags: UInt32 {
        UInt32(IFF_UP) | UInt32(IFF_RUNNING)
    }

    private var activePointToPointFlags: UInt32 {
        activeFlags | UInt32(IFF_POINTOPOINT)
    }
}
