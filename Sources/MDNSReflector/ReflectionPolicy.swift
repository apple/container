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

/// A host interface to advertise a service on, and the host port to advertise.
struct ReflectionTarget: Hashable, Sendable {
    let interface: HostInterface
    let hostPort: UInt16
}

/// The rules that decide where a container's service is advertised.
///
/// A service is advertised on a host interface only when a client on that
/// interface's network can reach it, which requires a published port that
/// forwards to the service and that listens on an address of the interface.
enum ReflectionPolicy {
    /// Name prefixes of the peer-to-peer Wi-Fi interfaces. The system leaves
    /// these out of ordinary service registrations, and so does the reflector.
    static let peerToPeerInterfacePrefixes = ["awdl", "llw"]

    /// Whether services can be advertised on the interface at all.
    static func isEligible(_ interface: HostInterface) -> Bool {
        guard interface.isUp, interface.supportsMulticast, !interface.isLoopback, !interface.isPointToPoint else {
            return false
        }
        guard !peerToPeerInterfacePrefixes.contains(where: { interface.name.hasPrefix($0) }) else {
            return false
        }
        return !interface.addresses.isEmpty
    }

    /// Whether a listener bound to `hostAddress` accepts connections that
    /// arrive on the interface.
    static func isReachable(through hostAddress: IPAddress, on interface: HostInterface) -> Bool {
        guard !hostAddress.isLoopback else {
            return false
        }
        guard hostAddress.isUnspecified else {
            return interface.addresses.contains(hostAddress)
        }
        // A wildcard listener accepts connections for its own address family.
        return interface.addresses.contains { $0.isV4 == hostAddress.isV4 }
    }

    /// The host port that `publishedPort` forwards to a container port, if any.
    static func hostPort(
        forContainerPort containerPort: UInt16,
        transport: PublishProtocol,
        publishedPort: PublishPort
    ) -> UInt16? {
        guard publishedPort.proto == transport, containerPort >= publishedPort.containerPort else {
            return nil
        }
        let offset = containerPort - publishedPort.containerPort
        guard offset < publishedPort.count else {
            return nil
        }
        return publishedPort.hostPort + offset
    }

    /// The interfaces to advertise a service on, each with the host port that
    /// reaches the service through that interface.
    ///
    /// At most one interface is chosen for each network. A host can have two
    /// interfaces on one network, such as Wi-Fi and Ethernet, and then each
    /// registration hears the other. Two registrations of one name are safe
    /// only while their records are identical, which an update of the TXT
    /// record does not guarantee, so the responder can take its own second
    /// copy for a conflict and rename it.
    ///
    /// - Parameters:
    ///   - containerPort: The port that the service listens on in the container.
    ///   - transport: The transport of the service.
    ///   - publishedPorts: The published ports of the container.
    ///   - interfaces: The current interfaces of the host.
    ///   - excludedInterfaces: Names of interfaces to never advertise on.
    ///   - preferredInterfaces: Names of interfaces to choose first among those
    ///     on one network, so that a service stays where it is advertised.
    static func targets(
        containerPort: UInt16,
        transport: PublishProtocol,
        publishedPorts: [PublishPort],
        interfaces: [HostInterface],
        excludedInterfaces: Set<String>,
        preferredInterfaces: Set<String> = []
    ) -> [ReflectionTarget] {
        let candidates: [ReflectionTarget] = interfaces.compactMap { interface in
            guard !excludedInterfaces.contains(interface.name), isEligible(interface) else {
                return nil
            }
            for publishedPort in publishedPorts {
                guard
                    let hostPort = hostPort(forContainerPort: containerPort, transport: transport, publishedPort: publishedPort),
                    isReachable(through: publishedPort.hostAddress, on: interface)
                else {
                    continue
                }
                return ReflectionTarget(interface: interface, hostPort: hostPort)
            }
            return nil
        }

        var claimed = Set<HostInterface.Subnet>()
        var chosen = Set<String>()
        let byPreference =
            candidates.filter { preferredInterfaces.contains($0.interface.name) }
            + candidates.filter { !preferredInterfaces.contains($0.interface.name) }
        for candidate in byPreference {
            let subnets = Set(candidate.interface.subnets.filter { !$0.isLinkLocal })
            guard claimed.isDisjoint(with: subnets) else {
                continue
            }
            claimed.formUnion(subnets)
            chosen.insert(candidate.interface.name)
        }
        return candidates.filter { chosen.contains($0.interface.name) }
    }
}
