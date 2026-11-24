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
import ContainerizationError
import ContainerizationExtras
import Testing

@testable import ContainerBuild

struct BuilderStartTests {
    @Test
    func dnsConfigurationChangedTreatsMissingAndEmptyAsEquivalent() {
        let desired = ContainerConfiguration.DNSConfiguration()

        #expect(!Builder.dnsConfigurationChanged(existing: nil, desired: desired))
    }

    @Test
    func dnsConfigurationChangedDetectsRemovedConfiguration() {
        let existing = ContainerConfiguration.DNSConfiguration(
            nameservers: ["1.1.1.1"],
            domain: "corp.local",
            searchDomains: ["corp.local"],
            options: ["ndots:2"]
        )
        let desired = ContainerConfiguration.DNSConfiguration()

        #expect(Builder.dnsConfigurationChanged(existing: existing, desired: desired))
    }

    @Test
    func dnsConfigurationChangedDetectsAddedConfiguration() {
        let desired = ContainerConfiguration.DNSConfiguration(
            nameservers: ["8.8.8.8"],
            domain: "lab.local",
            searchDomains: ["lab.local"],
            options: ["timeout:1"]
        )

        #expect(Builder.dnsConfigurationChanged(existing: nil, desired: desired))
    }

    @Test
    func resolveDesiredNetworksDefaultsToBuiltinForNewBuilder() throws {
        let desired = try Builder.resolveDesiredNetworks(
            requested: [],
            existing: nil,
            builtinNetworkId: "default",
            dnsDomain: "test"
        )

        #expect(desired.count == 1)
        #expect(desired[0].network == "default")
        #expect(desired[0].options.hostname == "buildkit.test.")
        #expect(desired[0].options.mtu == 1280)
    }

    @Test
    func resolveDesiredNetworksFailsWithoutBuiltinNetwork() {
        #expect {
            _ = try Builder.resolveDesiredNetworks(
                requested: [],
                existing: nil,
                builtinNetworkId: nil,
                dnsDomain: nil
            )
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            return err.code == .invalidState
        }
    }

    @Test
    func resolveDesiredNetworksPreservesExistingWhenOmitted() throws {
        let existing = [
            AttachmentConfiguration(
                network: "custom-net",
                options: AttachmentOptions(hostname: "buildkit.test.", mtu: 1500)
            )
        ]

        let desired = try Builder.resolveDesiredNetworks(
            requested: [],
            existing: existing,
            builtinNetworkId: "default",
            dnsDomain: "test"
        )

        #expect(desired == existing)
        #expect(!Builder.networksChanged(existing: existing, desired: desired))
    }

    @Test
    func resolveDesiredNetworksPreservesNoneWhenOmitted() throws {
        let existing: [AttachmentConfiguration] = []

        let desired = try Builder.resolveDesiredNetworks(
            requested: [],
            existing: existing,
            builtinNetworkId: "default",
            dnsDomain: "test"
        )

        #expect(desired.isEmpty)
        #expect(!Builder.networksChanged(existing: existing, desired: desired))
    }

    @Test
    func resolveDesiredNetworksSupportsNone() throws {
        let existing = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(hostname: "buildkit", mtu: 1280)
            )
        ]

        let desired = try Builder.resolveDesiredNetworks(
            requested: ["none"],
            existing: existing,
            builtinNetworkId: "default",
            dnsDomain: nil
        )

        #expect(desired.isEmpty)
        #expect(Builder.networksChanged(existing: existing, desired: desired))
    }

    @available(macOS 26, *)
    @Test
    func resolveDesiredNetworksDetectsNetworkSwitch() throws {
        let existing = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(hostname: "buildkit.test.", mtu: 1280)
            )
        ]

        let desired = try Builder.resolveDesiredNetworks(
            requested: ["registry-net"],
            existing: existing,
            builtinNetworkId: "default",
            dnsDomain: "test"
        )

        #expect(desired.count == 1)
        #expect(desired[0].network == "registry-net")
        #expect(desired[0].options.hostname == "buildkit.test.")
        #expect(Builder.networksChanged(existing: existing, desired: desired))
    }

    @available(macOS 26, *)
    @Test
    func resolveDesiredNetworksSwitchesBackToDefaultWhenExplicit() throws {
        let existing = [
            AttachmentConfiguration(
                network: "registry-net",
                options: AttachmentOptions(hostname: "buildkit.test.", mtu: 1280)
            )
        ]

        let desired = try Builder.resolveDesiredNetworks(
            requested: ["default"],
            existing: existing,
            builtinNetworkId: "default",
            dnsDomain: "test"
        )

        #expect(desired.count == 1)
        #expect(desired[0].network == "default")
        #expect(Builder.networksChanged(existing: existing, desired: desired))
    }

    @available(macOS 26, *)
    @Test
    func resolveDesiredNetworksSupportsMultipleNetworks() throws {
        let desired = try Builder.resolveDesiredNetworks(
            requested: ["registry-net,mtu=1500", "default"],
            existing: nil,
            builtinNetworkId: "default",
            dnsDomain: "test"
        )

        #expect(desired.count == 2)
        #expect(desired[0].network == "registry-net")
        #expect(desired[0].options.hostname == "buildkit.test.")
        #expect(desired[0].options.mtu == 1500)
        #expect(desired[1].network == "default")
        #expect(desired[1].options.hostname == "buildkit")
        #expect(desired[1].options.mtu == 1280)
    }

    @Test
    func networksChangedDetectsPropertyChanges() throws {
        let existing = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(hostname: "buildkit", macAddress: try MACAddress("02:42:ac:11:00:02"), mtu: 1500)
            )
        ]
        let same = try Builder.resolveDesiredNetworks(
            requested: ["default,mac=02:42:ac:11:00:02,mtu=1500"],
            existing: existing,
            builtinNetworkId: "default",
            dnsDomain: nil
        )
        let differentMtu = try Builder.resolveDesiredNetworks(
            requested: ["default,mac=02:42:ac:11:00:02"],
            existing: existing,
            builtinNetworkId: "default",
            dnsDomain: nil
        )

        #expect(!Builder.networksChanged(existing: existing, desired: same))
        #expect(Builder.networksChanged(existing: existing, desired: differentMtu))
    }
}
