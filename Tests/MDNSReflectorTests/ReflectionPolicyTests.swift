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

struct ServiceTypeTests {
    @Test
    func parsesNameAndTransport() throws {
        let hap = try #require(ServiceType("_hap._tcp"))
        #expect(hap.name == "_hap")
        #expect(hap.transport == .tcp)
        #expect(hap.description == "_hap._tcp")

        let sleepProxy = try #require(ServiceType("_sleep-proxy._udp"))
        #expect(sleepProxy.transport == .udp)
        #expect(sleepProxy.description == "_sleep-proxy._udp")
    }

    @Test
    func ignoresDomainTrailingDotAndCase() throws {
        #expect(ServiceType("_hap._tcp.local.") == ServiceType("_hap._tcp"))
        #expect(ServiceType("_HAP._TCP.") == ServiceType("_hap._tcp"))
    }

    @Test(arguments: ["", "_hap", "hap._tcp", "_._tcp", "_hap._sctp", "_printer._sub._http._tcp", "homebridge.local."])
    func rejectsWhatIsNotAServiceType(text: String) {
        #expect(ServiceType(text) == nil)
    }
}

struct ReflectionPolicyTests {
    @Test
    func mapsAContainerPortToItsHostPort() {
        let single = publish(host: 8080, container: 80)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 80, transport: .tcp, publishedPort: single) == 8080)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 81, transport: .tcp, publishedPort: single) == nil)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 79, transport: .tcp, publishedPort: single) == nil)
    }

    @Test
    func mapsWithinAPortRange() {
        let range = publish(host: 9000, container: 8000, count: 100)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 8000, transport: .tcp, publishedPort: range) == 9000)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 8099, transport: .tcp, publishedPort: range) == 9099)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 8100, transport: .tcp, publishedPort: range) == nil)
    }

    @Test
    func mapsARangeThatEndsAtTheLastPort() {
        let range = publish(host: 65530, container: 65530, count: 6)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 65535, transport: .tcp, publishedPort: range) == 65535)
    }

    @Test
    func doesNotMapAcrossTransports() {
        let udp = publish(host: 5353, container: 5353, proto: .udp)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 5353, transport: .tcp, publishedPort: udp) == nil)
        #expect(ReflectionPolicy.hostPort(forContainerPort: 5353, transport: .udp, publishedPort: udp) == 5353)
    }

    @Test
    func advertisesOnlyOnInterfacesThatCanCarryIt() {
        #expect(ReflectionPolicy.isEligible(.ethernet))
        #expect(!ReflectionPolicy.isEligible(.loopback))
        #expect(!ReflectionPolicy.isEligible(HostInterface(name: "en5", index: 8, addresses: [ip("192.168.1.11")], isUp: false)))
        #expect(!ReflectionPolicy.isEligible(HostInterface(name: "utun4", index: 24, addresses: [ip("10.8.0.2")], isPointToPoint: true)))
        #expect(!ReflectionPolicy.isEligible(HostInterface(name: "en6", index: 9, addresses: [ip("192.168.1.12")], supportsMulticast: false)))
        // An interface without an address has no host to resolve to.
        #expect(!ReflectionPolicy.isEligible(HostInterface(name: "en4", index: 7, addresses: [])))
        // Peer-to-peer Wi-Fi.
        #expect(!ReflectionPolicy.isEligible(HostInterface(name: "awdl0", index: 16, addresses: [ip("fe80::2")])))
        #expect(!ReflectionPolicy.isEligible(HostInterface(name: "llw0", index: 17, addresses: [ip("fe80::3")])))
    }

    @Test
    func aWildcardListenerIsReachableOnItsOwnAddressFamily() {
        let v6Only = HostInterface(name: "en7", index: 40, addresses: [ip("fd00::7")])

        #expect(ReflectionPolicy.isReachable(through: ip("0.0.0.0"), on: .ethernet))
        #expect(!ReflectionPolicy.isReachable(through: ip("0.0.0.0"), on: v6Only))
        #expect(ReflectionPolicy.isReachable(through: ip("::"), on: v6Only))
        #expect(!ReflectionPolicy.isReachable(through: ip("::"), on: .wifi))
    }

    @Test
    func aSpecificListenerIsReachableOnlyOnItsInterface() {
        #expect(ReflectionPolicy.isReachable(through: ip("192.168.1.10"), on: .ethernet))
        #expect(!ReflectionPolicy.isReachable(through: ip("192.168.1.10"), on: .wifi))
    }

    @Test
    func aLoopbackListenerIsNotReachable() {
        #expect(!ReflectionPolicy.isReachable(through: ip("127.0.0.1"), on: .ethernet))
        #expect(!ReflectionPolicy.isReachable(through: ip("::1"), on: .ethernet))
    }

    @Test
    func targetsSkipExcludedAndIneligibleInterfaces() {
        let targets = ReflectionPolicy.targets(
            containerPort: 51826,
            transport: .tcp,
            publishedPorts: [publish(host: 51826, container: 51826)],
            interfaces: [.loopback, .ethernet, .wifi, .bridge],
            excludedInterfaces: [HostInterface.bridge.name]
        )
        #expect(targets == [ReflectionTarget(interface: .ethernet, hostPort: 51826), ReflectionTarget(interface: .wifi, hostPort: 51826)])
    }

    @Test
    func targetsUseTheFirstPublishedPortThatReachesEachInterface() {
        // The same container port, published once per interface on different host ports.
        let targets = ReflectionPolicy.targets(
            containerPort: 80,
            transport: .tcp,
            publishedPorts: [
                publish("192.168.1.10", host: 8080, container: 80),
                publish("10.0.0.7", host: 9090, container: 80),
            ],
            interfaces: [.ethernet, .wifi],
            excludedInterfaces: []
        )
        #expect(targets == [ReflectionTarget(interface: .ethernet, hostPort: 8080), ReflectionTarget(interface: .wifi, hostPort: 9090)])
    }

    @Test
    func targetsOneInterfacePerNetwork() {
        // Two interfaces on one network hear each other's registrations.
        let targets = ReflectionPolicy.targets(
            containerPort: 51826,
            transport: .tcp,
            publishedPorts: [publish(host: 51826, container: 51826)],
            interfaces: [.ethernet, .ethernetTwin, .wifi],
            excludedInterfaces: []
        )
        #expect(targets.map(\.interface.name) == ["en0", "en1"])
    }

    @Test
    func targetsKeepThePreferredInterfaceOfANetwork() {
        let targets = ReflectionPolicy.targets(
            containerPort: 51826,
            transport: .tcp,
            publishedPorts: [publish(host: 51826, container: 51826)],
            interfaces: [.ethernet, .ethernetTwin, .wifi],
            excludedInterfaces: [],
            preferredInterfaces: ["en10"]
        )
        #expect(targets.map(\.interface.name) == ["en10", "en1"])
    }

    @Test
    func linkLocalSubnetsDoNotPutInterfacesOnOneNetwork() {
        // Every interface has the same link-local subnet, whatever it is attached to.
        let first = HostInterface(name: "en7", index: 40, addresses: [ip("fe80::7")], subnets: [subnet("fe80::/64")])
        let second = HostInterface(name: "en8", index: 41, addresses: [ip("fe80::8")], subnets: [subnet("fe80::/64")])
        let targets = ReflectionPolicy.targets(
            containerPort: 51826,
            transport: .tcp,
            publishedPorts: [publish("::", host: 51826, container: 51826)],
            interfaces: [first, second],
            excludedInterfaces: []
        )
        #expect(targets.map(\.interface.name) == ["en7", "en8"])
    }

    @Test
    func noTargetsWithoutAMatchingPublishedPort() {
        let targets = ReflectionPolicy.targets(
            containerPort: 51826,
            transport: .tcp,
            publishedPorts: [publish(host: 8581, container: 8581)],
            interfaces: [.ethernet, .wifi],
            excludedInterfaces: []
        )
        #expect(targets.isEmpty)
    }
}

struct HostInterfaceTests {
    @Test
    func listsTheLoopbackInterface() throws {
        let interfaces = HostInterface.current()
        let loopback = try #require(interfaces.first { $0.isLoopback })
        #expect(loopback.isUp)
        #expect(loopback.index != 0)
        #expect(loopback.addresses.contains(ip("127.0.0.1")))
    }

    @Test
    func reportsTheSubnetOfAnAddress() throws {
        let loopback = try #require(HostInterface.current().first { $0.isLoopback })
        #expect(loopback.subnets.contains(subnet("127.0.0.0/8")))
    }

    @Test
    func listsEachInterfaceOnce() {
        let names = HostInterface.current().map(\.name)
        #expect(Set(names).count == names.count)
    }
}
