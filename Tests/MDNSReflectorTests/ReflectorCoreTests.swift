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
import ContainerizationExtras
import Testing

@testable import MDNSReflector

/// A reflector for a container at 192.168.64.2, on a host with a loopback
/// interface, one LAN interface and the container network's bridge.
private struct Fixture {
    static let containerAddress = "192.168.64.2"
    static let hap = ServiceInstance(name: "Homebridge 1A2B", type: ServiceType("_hap._tcp")!)

    let discovery = FakeDiscovery()
    let core: ReflectorCore

    init(publishedPorts: [PublishPort]) {
        self.core = ReflectorCore(
            configuration: .init(
                containerAddress: ipv4(Self.containerAddress),
                gateway: ipv4("192.168.64.1"),
                publishedPorts: publishedPorts
            ),
            discovery: discovery,
            log: quietLog
        )
    }

    func start(interfaces: [HostInterface] = [.loopback, .ethernet, .bridge]) throws {
        try core.start(interfaces: interfaces)
    }

    /// Walks a service through discovery: its type and name appear, it
    /// resolves, and its host turns out to have `address`.
    func announce(
        _ instance: ServiceInstance = Fixture.hap,
        host: String = "homebridge.local.",
        port: UInt16,
        txt: [UInt8] = txtRecord("sf=1"),
        address: String = Fixture.containerAddress
    ) throws {
        try #require(discovery.typeBrowses.count == 1)
        discovery.typeBrowses[0].handler(.added(instance.type.description))
        let browse = try #require(discovery.browses.last { $0.type == instance.type })
        browse.handler(.added(instance.name))
        try resolve(instance, host: host, port: port, txt: txt)
        let lookup = try #require(discovery.lookups.last { $0.host == host })
        lookup.handler([ipv4(address)])
    }

    func resolve(_ instance: ServiceInstance = Fixture.hap, host: String = "homebridge.local.", port: UInt16, txt: [UInt8]) throws {
        let resolve = try #require(discovery.resolves.last { $0.instance == instance })
        resolve.handler(ResolvedService(host: host, port: port, txt: txt))
    }
}

struct ReflectorCoreTests {
    @Test
    func discoversOnTheContainerNetworkInterface() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826)

        #expect(fixture.discovery.typeBrowses.map(\.interfaceIndex) == [HostInterface.bridge.index])
        #expect(fixture.discovery.browses.map(\.interfaceIndex) == [HostInterface.bridge.index])
        #expect(fixture.discovery.resolves.map(\.interfaceIndex) == [HostInterface.bridge.index])
        #expect(fixture.discovery.lookups.map(\.interfaceIndex) == [HostInterface.bridge.index])
    }

    @Test
    func advertisesTheContainersServiceOnTheLAN() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826, txt: txtRecord("sf=1", "id=0E:22:22:E2:22:22"))

        // Not on the loopback interface, and not back onto the container network.
        let registrations = fixture.discovery.activeRegistrations
        #expect(registrations.map(\.interfaceIndex) == [HostInterface.ethernet.index])
        #expect(registrations.first?.instance == Fixture.hap)
        #expect(registrations.first?.port == 51826)
        #expect(registrations.first?.txt == txtRecord("sf=1", "id=0E:22:22:E2:22:22"))
    }

    @Test
    func advertisesTheHostPortNotTheContainerPort() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 8080, container: 80, count: 10)])
        try fixture.start()
        try fixture.announce(ServiceInstance(name: "web", type: ServiceType("_http._tcp")!), port: 83)

        #expect(fixture.discovery.activeRegistrations.map(\.port) == [8083])
    }

    @Test
    func ignoresServicesOfOtherHostsOnTheContainerNetwork() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        // The host's own services and other containers are visible on the same interface.
        try fixture.announce(port: 51826, address: "192.168.64.1")

        #expect(fixture.discovery.registrations.isEmpty)
        // It is not followed any further.
        #expect(fixture.discovery.resolves.allSatisfy { $0.operation.cancelled })
        #expect(fixture.discovery.lookups.allSatisfy { $0.operation.cancelled })
    }

    @Test
    func doesNotAdvertiseAServiceOnAnUnpublishedPort() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 8581, container: 8581)])
        try fixture.start()
        try fixture.announce(port: 51826)

        #expect(fixture.discovery.registrations.isEmpty)
    }

    @Test
    func doesNotAdvertiseAServicePublishedOnLoopbackOnly() throws {
        let fixture = Fixture(publishedPorts: [publish("127.0.0.1", host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826)

        #expect(fixture.discovery.registrations.isEmpty)
    }

    @Test
    func doesNotBrowseTypesOfAnUnpublishedTransport() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826, proto: .tcp)])
        try fixture.start()
        fixture.discovery.typeBrowses[0].handler(.added("_sleep-proxy._udp"))

        #expect(fixture.discovery.browses.isEmpty)
    }

    @Test
    func browsesEachTypeOnce() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        fixture.discovery.typeBrowses[0].handler(.added("_hap._tcp"))
        fixture.discovery.typeBrowses[0].handler(.added("_hap._tcp"))
        fixture.discovery.typeBrowses[0].handler(.added("not a service type"))

        #expect(fixture.discovery.browses.count == 1)
    }

    @Test
    func waitsForTheHostToHaveAnAddressBeforeDeciding() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        fixture.discovery.typeBrowses[0].handler(.added("_hap._tcp"))
        fixture.discovery.browses[0].handler(.added(Fixture.hap.name))
        try fixture.resolve(port: 51826, txt: txtRecord("sf=1"))

        // An empty answer says nothing about who provides the service.
        fixture.discovery.lookups[0].handler([])
        #expect(fixture.discovery.registrations.isEmpty)
        #expect(!fixture.discovery.lookups[0].operation.cancelled)

        fixture.discovery.lookups[0].handler([ipv4(Fixture.containerAddress)])
        #expect(fixture.discovery.activeRegistrations.count == 1)
    }

    @Test
    func carriesOverATXTRecordChange() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826, txt: txtRecord("sf=1", "c#=2"))

        // Pairing clears the status flag and a new accessory bumps the configuration number.
        try fixture.resolve(port: 51826, txt: txtRecord("sf=0", "c#=3"))

        #expect(fixture.discovery.registrations.count == 1)
        #expect(fixture.discovery.registrations[0].operation.txtUpdates == [txtRecord("sf=0", "c#=3")])
    }

    @Test
    func leavesAnUnchangedTXTRecordAlone() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826, txt: txtRecord("sf=1"))

        try fixture.resolve(port: 51826, txt: txtRecord("sf=1"))

        #expect(fixture.discovery.registrations.count == 1)
        #expect(fixture.discovery.registrations[0].operation.txtUpdates.isEmpty)
    }

    @Test
    func reRegistersWhenThePortChanges() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 9000, container: 9000, count: 2)])
        try fixture.start()
        try fixture.announce(port: 9000)

        try fixture.resolve(port: 9001, txt: txtRecord("sf=1"))

        #expect(fixture.discovery.registrations.count == 2)
        #expect(fixture.discovery.registrations[0].operation.cancelled)
        #expect(fixture.discovery.activeRegistrations.map(\.port) == [9001])
    }

    @Test
    func checksOwnershipAgainWhenTheHostChanges() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826)
        #expect(fixture.discovery.activeRegistrations.count == 1)

        // The same name now points at a host that is not the container.
        try fixture.resolve(host: "other.local.", port: 51826, txt: txtRecord("sf=1"))
        #expect(fixture.discovery.activeRegistrations.isEmpty)

        let lookup = try #require(fixture.discovery.lookups.last)
        #expect(lookup.host == "other.local.")
        lookup.handler([ipv4("192.168.64.9")])
        #expect(fixture.discovery.activeRegistrations.isEmpty)
    }

    @Test
    func withdrawsAServiceThatTheContainerStopsAnnouncing() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826)

        fixture.discovery.browses[0].handler(.removed(Fixture.hap.name))

        #expect(fixture.discovery.activeRegistrations.isEmpty)
        #expect(fixture.discovery.resolves[0].operation.cancelled)
    }

    @Test
    func advertisesAgainWhenAServiceReturns() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826)
        fixture.discovery.browses[0].handler(.removed(Fixture.hap.name))

        fixture.discovery.browses[0].handler(.added(Fixture.hap.name))
        try fixture.resolve(port: 51826, txt: txtRecord("sf=0"))
        try #require(fixture.discovery.lookups.count == 2)
        fixture.discovery.lookups[1].handler([ipv4(Fixture.containerAddress)])

        #expect(fixture.discovery.activeRegistrations.map(\.txt) == [txtRecord("sf=0")])
    }

    @Test
    func ignoresResultsOfAWithdrawnService() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        fixture.discovery.typeBrowses[0].handler(.added("_hap._tcp"))
        fixture.discovery.browses[0].handler(.added(Fixture.hap.name))
        try fixture.resolve(port: 51826, txt: txtRecord("sf=1"))
        fixture.discovery.browses[0].handler(.removed(Fixture.hap.name))

        // A result that was already on its way when the service went away.
        fixture.discovery.lookups[0].handler([ipv4(Fixture.containerAddress)])

        #expect(fixture.discovery.registrations.isEmpty)
    }

    @Test
    func followsTheHostsInterfaces() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826)

        fixture.core.interfacesChanged([.loopback, .ethernet, .wifi, .bridge])
        #expect(Set(fixture.discovery.activeRegistrations.map(\.interfaceIndex)) == [HostInterface.ethernet.index, HostInterface.wifi.index])

        fixture.core.interfacesChanged([.loopback, .wifi, .bridge])
        #expect(fixture.discovery.activeRegistrations.map(\.interfaceIndex) == [HostInterface.wifi.index])

        // The registration on the interface that stayed was not disturbed.
        #expect(fixture.discovery.registrations.count == 2)
    }

    @Test
    func advertisesOncePerNetwork() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start(interfaces: [.loopback, .ethernet, .ethernetTwin, .bridge])
        try fixture.announce(port: 51826)

        #expect(fixture.discovery.activeRegistrations.map(\.interfaceIndex) == [HostInterface.ethernet.index])
    }

    @Test
    func movesToTheOtherInterfaceOfANetworkWhenOneGoesAway() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start(interfaces: [.loopback, .ethernet, .ethernetTwin, .bridge])
        try fixture.announce(port: 51826)

        fixture.core.interfacesChanged([.loopback, .ethernetTwin, .bridge])

        #expect(fixture.discovery.activeRegistrations.map(\.interfaceIndex) == [HostInterface.ethernetTwin.index])
    }

    @Test
    func staysOnItsInterfaceWhenAnotherJoinsTheNetwork() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start(interfaces: [.loopback, .ethernetTwin, .bridge])
        try fixture.announce(port: 51826)

        // The new interface comes first in the system's order, but the service is not moved.
        fixture.core.interfacesChanged([.loopback, .ethernet, .ethernetTwin, .bridge])

        #expect(fixture.discovery.registrations.count == 1)
        #expect(fixture.discovery.activeRegistrations.map(\.interfaceIndex) == [HostInterface.ethernetTwin.index])
    }

    @Test
    func advertisesOnlyOnTheInterfaceOfASpecificHostAddress() throws {
        let fixture = Fixture(publishedPorts: [publish("10.0.0.7", host: 51826, container: 51826)])
        try fixture.start(interfaces: [.loopback, .ethernet, .wifi, .bridge])
        try fixture.announce(port: 51826)

        #expect(fixture.discovery.activeRegistrations.map(\.interfaceIndex) == [HostInterface.wifi.index])
    }

    @Test
    func startsDiscoveryOnceTheContainerNetworkInterfaceAppears() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start(interfaces: [.loopback, .ethernet])
        #expect(fixture.discovery.typeBrowses.isEmpty)

        fixture.core.interfacesChanged([.loopback, .ethernet, .bridge])
        #expect(fixture.discovery.typeBrowses.map(\.interfaceIndex) == [HostInterface.bridge.index])

        try fixture.announce(port: 51826)
        #expect(fixture.discovery.activeRegistrations.count == 1)
    }

    @Test
    func stopWithdrawsEverything() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        try fixture.announce(port: 51826)

        fixture.core.stop()

        #expect(fixture.discovery.activeRegistrations.isEmpty)
        #expect(fixture.discovery.typeBrowses.allSatisfy { $0.operation.cancelled })
        #expect(fixture.discovery.browses.allSatisfy { $0.operation.cancelled })
        #expect(fixture.discovery.resolves.allSatisfy { $0.operation.cancelled })
    }

    @Test
    func doesNothingAfterStop() throws {
        let fixture = Fixture(publishedPorts: [publish(host: 51826, container: 51826)])
        try fixture.start()
        fixture.discovery.typeBrowses[0].handler(.added("_hap._tcp"))
        fixture.core.stop()

        fixture.discovery.typeBrowses[0].handler(.added("_http._tcp"))
        fixture.discovery.browses[0].handler(.added(Fixture.hap.name))
        fixture.core.interfacesChanged([.loopback, .wifi, .bridge])

        #expect(fixture.discovery.browses.count == 1)
        #expect(fixture.discovery.resolves.isEmpty)
        #expect(fixture.discovery.registrations.isEmpty)
    }
}
