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

/// A running discovery operation.
protocol DiscoveryOperation: AnyObject {
    /// Stops the operation. No handler is called after this returns.
    func cancel()
}

/// A service registered with the host's mDNS responder.
protocol ServiceRegistration: DiscoveryOperation {
    /// Replaces the TXT record of the registered service.
    func updateTXT(_ txt: [UInt8]) throws
}

/// An item appearing in or disappearing from a browse result.
enum BrowseEvent<Item> {
    case added(Item)
    case removed(Item)
}

/// The outcome of a service registration.
enum RegistrationEvent: Equatable {
    /// The service is registered under `name`, which differs from the
    /// requested name when that one was already taken on the network.
    case registered(name: String)
    /// The registration failed with a DNS-SD error code.
    case failed(code: Int32)
}

/// The DNS-SD operations that the reflector is built from.
///
/// Every operation is scoped to one interface. An implementation calls the
/// handlers on the same serial queue that the reflector calls it on, so that
/// no handler runs while the reflector is changing its state.
protocol ServiceDiscovery: AnyObject {
    /// Enumerates the service types advertised on an interface, each in the
    /// form `_name._transport`.
    func browseServiceTypes(
        interfaceIndex: UInt32,
        handler: @escaping (BrowseEvent<String>) -> Void
    ) throws -> any DiscoveryOperation

    /// Enumerates the names of the instances of a service type on an interface.
    func browse(
        type: ServiceType,
        interfaceIndex: UInt32,
        handler: @escaping (BrowseEvent<String>) -> Void
    ) throws -> any DiscoveryOperation

    /// Resolves a service instance, and reports again whenever its host, port
    /// or TXT record changes.
    func resolve(
        _ instance: ServiceInstance,
        interfaceIndex: UInt32,
        handler: @escaping (ResolvedService) -> Void
    ) throws -> any DiscoveryOperation

    /// Looks up the IPv4 addresses of a host name. The handler receives each
    /// complete set of answers, which is empty when the name has no address.
    func lookupIPv4Addresses(
        host: String,
        interfaceIndex: UInt32,
        handler: @escaping ([IPv4Address]) -> Void
    ) throws -> any DiscoveryOperation

    /// Registers a service on one interface, provided by this host.
    func register(
        _ instance: ServiceInstance,
        interfaceIndex: UInt32,
        port: UInt16,
        txt: [UInt8],
        handler: @escaping (RegistrationEvent) -> Void
    ) throws -> any ServiceRegistration
}
