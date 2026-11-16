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
import Foundation
import Logging

// Only the monitor: the Network module has an address type of its own that
// shares a name with the one used here.
import class Network.NWPathMonitor

/// Advertises the mDNS services of a container on the host's networks.
///
/// A container's mDNS announcements reach the host on the interface of the
/// container's network, but go no further, and they name an address that
/// only the host can reach. The reflector finds the services that the
/// container announces there and registers each one with the host's mDNS
/// responder on the host's other interfaces, as a service of the host on the
/// published port that forwards to it. A service on a port that is not
/// published is not advertised, because nothing outside the host could
/// connect to it.
///
/// The registrations follow the container: a change to a service's TXT record
/// or port is carried over, and a service that the container stops announcing
/// is withdrawn.
public final class MDNSReflector: @unchecked Sendable {
    /// What the reflector needs to know about a container.
    public struct Configuration: Sendable {
        /// The IPv4 address of the container on its network.
        public var containerAddress: IPv4Address

        /// The IPv4 address of the host on the container's network.
        public var gateway: IPv4Address

        /// The ports that the container publishes on the host.
        public var publishedPorts: [PublishPort]

        public init(containerAddress: IPv4Address, gateway: IPv4Address, publishedPorts: [PublishPort]) {
            self.containerAddress = containerAddress
            self.gateway = gateway
            self.publishedPorts = publishedPorts
        }
    }

    // The core and the path monitor are confined to the queue.
    private let queue = DispatchQueue(label: "com.apple.container.mdns-reflector")
    private let core: ReflectorCore
    private var pathMonitor: NWPathMonitor?

    public init(configuration: Configuration, log: Logger) {
        let discovery = DNSSDServiceDiscovery(queue: queue, log: log)
        self.core = ReflectorCore(configuration: configuration, discovery: discovery, log: log)
    }

    /// Starts advertising the container's services.
    public func start() throws {
        try queue.sync {
            try core.start(interfaces: HostInterface.current())

            // Network changes move the registrations to the interfaces that
            // the services are reachable on.
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                self?.core.interfacesChanged(HostInterface.current())
            }
            monitor.start(queue: queue)
            pathMonitor = monitor
        }
    }

    /// Stops advertising and withdraws the container's services.
    public func stop() {
        queue.sync {
            pathMonitor?.cancel()
            pathMonitor = nil
            core.stop()
        }
    }
}
