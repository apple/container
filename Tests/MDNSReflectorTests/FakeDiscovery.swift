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
import Logging

@testable import MDNSReflector

/// An operation that records what the reflector does with it.
final class FakeOperation: ServiceRegistration {
    private(set) var cancelled = false
    private(set) var txtUpdates: [[UInt8]] = []

    func cancel() {
        cancelled = true
    }

    func updateTXT(_ txt: [UInt8]) throws {
        txtUpdates.append(txt)
    }
}

/// A discovery backend that records the operations the reflector starts, and
/// lets a test deliver their results.
final class FakeDiscovery: ServiceDiscovery {
    struct TypeBrowse {
        let interfaceIndex: UInt32
        let handler: (BrowseEvent<String>) -> Void
        let operation: FakeOperation
    }

    struct Browse {
        let type: ServiceType
        let interfaceIndex: UInt32
        let handler: (BrowseEvent<String>) -> Void
        let operation: FakeOperation
    }

    struct Resolve {
        let instance: ServiceInstance
        let interfaceIndex: UInt32
        let handler: (ResolvedService) -> Void
        let operation: FakeOperation
    }

    struct Lookup {
        let host: String
        let interfaceIndex: UInt32
        let handler: ([IPv4Address]) -> Void
        let operation: FakeOperation
    }

    struct Registration {
        let instance: ServiceInstance
        let interfaceIndex: UInt32
        let port: UInt16
        let txt: [UInt8]
        let handler: (RegistrationEvent) -> Void
        let operation: FakeOperation
    }

    private(set) var typeBrowses: [TypeBrowse] = []
    private(set) var browses: [Browse] = []
    private(set) var resolves: [Resolve] = []
    private(set) var lookups: [Lookup] = []
    private(set) var registrations: [Registration] = []

    /// The registrations that have not been withdrawn.
    var activeRegistrations: [Registration] {
        registrations.filter { !$0.operation.cancelled }
    }

    func browseServiceTypes(
        interfaceIndex: UInt32,
        handler: @escaping (BrowseEvent<String>) -> Void
    ) throws -> any DiscoveryOperation {
        let operation = FakeOperation()
        typeBrowses.append(TypeBrowse(interfaceIndex: interfaceIndex, handler: handler, operation: operation))
        return operation
    }

    func browse(
        type: ServiceType,
        interfaceIndex: UInt32,
        handler: @escaping (BrowseEvent<String>) -> Void
    ) throws -> any DiscoveryOperation {
        let operation = FakeOperation()
        browses.append(Browse(type: type, interfaceIndex: interfaceIndex, handler: handler, operation: operation))
        return operation
    }

    func resolve(
        _ instance: ServiceInstance,
        interfaceIndex: UInt32,
        handler: @escaping (ResolvedService) -> Void
    ) throws -> any DiscoveryOperation {
        let operation = FakeOperation()
        resolves.append(Resolve(instance: instance, interfaceIndex: interfaceIndex, handler: handler, operation: operation))
        return operation
    }

    func lookupIPv4Addresses(
        host: String,
        interfaceIndex: UInt32,
        handler: @escaping ([IPv4Address]) -> Void
    ) throws -> any DiscoveryOperation {
        let operation = FakeOperation()
        lookups.append(Lookup(host: host, interfaceIndex: interfaceIndex, handler: handler, operation: operation))
        return operation
    }

    func register(
        _ instance: ServiceInstance,
        interfaceIndex: UInt32,
        port: UInt16,
        txt: [UInt8],
        handler: @escaping (RegistrationEvent) -> Void
    ) throws -> any ServiceRegistration {
        let operation = FakeOperation()
        registrations.append(
            Registration(instance: instance, interfaceIndex: interfaceIndex, port: port, txt: txt, handler: handler, operation: operation))
        return operation
    }
}

func ip(_ text: String) -> IPAddress {
    try! IPAddress(text)
}

func ipv4(_ text: String) -> IPv4Address {
    try! IPv4Address(text)
}

func publish(_ hostAddress: String = "0.0.0.0", host: UInt16, container: UInt16, proto: PublishProtocol = .tcp, count: UInt16 = 1) -> PublishPort {
    try! PublishPort(hostAddress: ip(hostAddress), hostPort: host, containerPort: container, proto: proto, count: count)
}

/// Encodes strings as the data of a TXT record.
func txtRecord(_ entries: String...) -> [UInt8] {
    entries.flatMap { entry in
        let bytes = Array(entry.utf8)
        return [UInt8(bytes.count)] + bytes
    }
}

let quietLog = Logger(label: "MDNSReflectorTests") { _ in SwiftLogNoOpLogHandler() }

/// Parses a subnet in CIDR notation, such as `192.168.1.0/24`.
func subnet(_ cidr: String) -> HostInterface.Subnet {
    let parts = cidr.split(separator: "/")
    return HostInterface.Subnet(network: ip(String(parts[0])), prefixLength: UInt8(parts[1])!)
}

extension HostInterface {
    static let loopback = HostInterface(
        name: "lo0", index: 1, addresses: [ip("127.0.0.1")], subnets: [subnet("127.0.0.0/8")], isLoopback: true)
    static let ethernet = HostInterface(
        name: "en0", index: 14, addresses: [ip("192.168.1.10"), ip("fe80::1")], subnets: [subnet("192.168.1.0/24"), subnet("fe80::/64")])
    /// A second interface on the same network as `ethernet`, as with Wi-Fi and Ethernet both connected.
    static let ethernetTwin = HostInterface(
        name: "en10", index: 30, addresses: [ip("192.168.1.12"), ip("fe80::9")], subnets: [subnet("192.168.1.0/24"), subnet("fe80::/64")])
    static let wifi = HostInterface(name: "en1", index: 15, addresses: [ip("10.0.0.7")], subnets: [subnet("10.0.0.0/24")])
    /// The host's interface on the container network.
    static let bridge = HostInterface(name: "bridge100", index: 32, addresses: [ip("192.168.64.1")], subnets: [subnet("192.168.64.0/24")])
}
