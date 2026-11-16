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

/// The state machine of the reflector.
///
/// It discovers the services that one container advertises on its network and
/// registers them on the other interfaces of the host. It is not thread safe:
/// every method, and every handler that it passes to the discovery backend,
/// must run on one serial queue.
final class ReflectorCore {
    private enum Ownership {
        /// The address of the host that provides the service is not known yet.
        case unknown
        /// The container provides the service.
        case owned
        /// Something else on the container network provides the service, such
        /// as the host itself or another container.
        case foreign
    }

    private struct RegistrationKey: Hashable {
        let interfaceName: String
        let interfaceIndex: UInt32
        let hostPort: UInt16
    }

    private struct Registration {
        let operation: any ServiceRegistration
        var txt: [UInt8]
    }

    private final class Instance {
        var resolveOperation: (any DiscoveryOperation)?
        var addressOperation: (any DiscoveryOperation)?
        var resolved: ResolvedService?
        var ownership: Ownership = .unknown
        var registrations: [RegistrationKey: Registration] = [:]
        var reportedUnreachable = false

        func cancelAll() {
            resolveOperation?.cancel()
            resolveOperation = nil
            addressOperation?.cancel()
            addressOperation = nil
            for registration in registrations.values {
                registration.operation.cancel()
            }
            registrations = [:]
        }
    }

    private let configuration: MDNSReflector.Configuration
    private let discovery: any ServiceDiscovery
    private let log: Logger

    private var running = false
    private var interfaces: [HostInterface] = []
    private var containerInterface: HostInterface?
    private var typeBrowse: (any DiscoveryOperation)?
    private var instanceBrowses: [ServiceType: any DiscoveryOperation] = [:]
    private var instances: [ServiceInstance: Instance] = [:]

    init(configuration: MDNSReflector.Configuration, discovery: any ServiceDiscovery, log: Logger) {
        self.configuration = configuration
        self.discovery = discovery
        self.log = log
    }

    /// Starts reflecting. Discovery begins once the host interface of the
    /// container's network is present, which may be after this call.
    func start(interfaces: [HostInterface]) throws {
        guard !running else {
            return
        }
        running = true
        self.interfaces = interfaces
        do {
            try beginDiscoveryIfPossible()
        } catch {
            running = false
            throw error
        }
    }

    /// Updates the interfaces of the host, and moves the registered services
    /// to the interfaces that they are now reachable on.
    func interfacesChanged(_ interfaces: [HostInterface]) {
        guard running, interfaces != self.interfaces else {
            return
        }
        self.interfaces = interfaces
        do {
            try beginDiscoveryIfPossible()
        } catch {
            log.error("failed to start mDNS discovery", metadata: ["error": "\(error)"])
        }
        for instance in Array(instances.keys) {
            reconcile(instance)
        }
    }

    /// Stops reflecting and withdraws every registered service.
    func stop() {
        guard running else {
            return
        }
        running = false
        typeBrowse?.cancel()
        typeBrowse = nil
        for browse in instanceBrowses.values {
            browse.cancel()
        }
        instanceBrowses = [:]
        for state in instances.values {
            state.cancelAll()
        }
        instances = [:]
        containerInterface = nil
    }

    private func beginDiscoveryIfPossible() throws {
        guard running, typeBrowse == nil else {
            return
        }
        // The host's interface on the container's network holds the gateway address.
        guard let interface = interfaces.first(where: { $0.addresses.contains(.v4(configuration.gateway)) }) else {
            log.debug("waiting for the container network interface", metadata: ["gateway": "\(configuration.gateway)"])
            return
        }
        containerInterface = interface
        typeBrowse = try discovery.browseServiceTypes(interfaceIndex: interface.index) { [weak self] event in
            self?.handle(serviceType: event)
        }
        log.info(
            "reflecting mDNS services",
            metadata: [
                "interface": "\(interface.name)",
                "container": "\(configuration.containerAddress)",
            ])
    }

    private func handle(serviceType event: BrowseEvent<String>) {
        // A type that is no longer advertised stays browsed; it costs nothing
        // and the service may return.
        guard running, case .added(let text) = event, let containerInterface else {
            return
        }
        guard let type = ServiceType(text), instanceBrowses[type] == nil else {
            return
        }
        // No published port of this transport means nothing of this type is reachable.
        guard configuration.publishedPorts.contains(where: { $0.proto == type.transport }) else {
            return
        }
        do {
            instanceBrowses[type] = try discovery.browse(type: type, interfaceIndex: containerInterface.index) { [weak self] event in
                self?.handle(instance: event, type: type)
            }
        } catch {
            log.warning("failed to browse mDNS service type", metadata: ["type": "\(type)", "error": "\(error)"])
        }
    }

    private func handle(instance event: BrowseEvent<String>, type: ServiceType) {
        guard running, let containerInterface else {
            return
        }
        switch event {
        case .added(let name):
            let instance = ServiceInstance(name: name, type: type)
            guard instances[instance] == nil else {
                return
            }
            let state = Instance()
            instances[instance] = state
            do {
                state.resolveOperation = try discovery.resolve(instance, interfaceIndex: containerInterface.index) { [weak self, weak state] service in
                    guard let self, let state, self.instances[instance] === state else {
                        return
                    }
                    self.handle(resolved: service, for: instance, state: state)
                }
            } catch {
                instances[instance] = nil
                log.warning("failed to resolve mDNS service", metadata: ["service": "\(instance)", "error": "\(error)"])
            }
        case .removed(let name):
            let instance = ServiceInstance(name: name, type: type)
            guard let state = instances.removeValue(forKey: instance) else {
                return
            }
            if !state.registrations.isEmpty {
                log.info("withdrawing mDNS service", metadata: ["service": "\(instance)"])
            }
            state.cancelAll()
        }
    }

    private func handle(resolved service: ResolvedService, for instance: ServiceInstance, state: Instance) {
        let previousHost = state.resolved?.host
        state.resolved = service

        if previousHost?.lowercased() != service.host.lowercased() {
            // A new host has to prove again that it is the container.
            state.ownership = .unknown
            state.addressOperation?.cancel()
            state.addressOperation = nil
            for registration in state.registrations.values {
                registration.operation.cancel()
            }
            state.registrations = [:]
            guard let containerInterface else {
                return
            }
            do {
                state.addressOperation = try discovery.lookupIPv4Addresses(host: service.host, interfaceIndex: containerInterface.index) {
                    [weak self, weak state] addresses in
                    guard let self, let state, self.instances[instance] === state else {
                        return
                    }
                    self.handle(addresses: addresses, for: instance, state: state)
                }
            } catch {
                log.warning("failed to look up mDNS host", metadata: ["host": "\(service.host)", "error": "\(error)"])
            }
            return
        }

        reconcile(instance)
    }

    private func handle(addresses: [IPv4Address], for instance: ServiceInstance, state: Instance) {
        // No address yet is not an answer about who provides the service.
        guard state.ownership == .unknown, !addresses.isEmpty else {
            return
        }
        state.addressOperation?.cancel()
        state.addressOperation = nil

        guard addresses.contains(configuration.containerAddress) else {
            // Not this container's service. Stop following it, but remember
            // it so that it is not resolved again while it stays advertised.
            state.ownership = .foreign
            state.resolveOperation?.cancel()
            state.resolveOperation = nil
            return
        }
        state.ownership = .owned
        reconcile(instance)
    }

    /// Makes the registrations of a service match its current port, TXT record
    /// and the interfaces it is reachable on.
    private func reconcile(_ instance: ServiceInstance) {
        guard running, let state = instances[instance], state.ownership == .owned, let service = state.resolved else {
            return
        }

        let targets = ReflectionPolicy.targets(
            containerPort: service.port,
            transport: instance.type.transport,
            publishedPorts: configuration.publishedPorts,
            interfaces: interfaces,
            excludedInterfaces: containerInterface.map { [$0.name] } ?? [],
            preferredInterfaces: Set(state.registrations.keys.map(\.interfaceName))
        )
        let wanted = Set(targets.map { key(for: $0) })

        for (key, registration) in state.registrations where !wanted.contains(key) {
            registration.operation.cancel()
            state.registrations[key] = nil
        }

        for target in targets {
            let key = key(for: target)
            if let registration = state.registrations[key] {
                guard registration.txt != service.txt else {
                    continue
                }
                do {
                    try registration.operation.updateTXT(service.txt)
                    state.registrations[key]?.txt = service.txt
                    log.debug(
                        "updated mDNS service TXT record",
                        metadata: ["service": "\(instance)", "interface": "\(target.interface.name)"])
                } catch {
                    log.warning("failed to update mDNS service", metadata: ["service": "\(instance)", "error": "\(error)"])
                }
                continue
            }
            register(instance, state: state, target: target, txt: service.txt)
        }

        if targets.isEmpty {
            reportUnreachable(instance, state: state, port: service.port)
        } else {
            state.reportedUnreachable = false
        }
    }

    private func register(_ instance: ServiceInstance, state: Instance, target: ReflectionTarget, txt: [UInt8]) {
        let log = self.log
        let interfaceName = target.interface.name
        do {
            let operation = try discovery.register(
                instance,
                interfaceIndex: target.interface.index,
                port: target.hostPort,
                txt: txt
            ) { event in
                switch event {
                case .registered(let name) where name == instance.name:
                    log.info(
                        "advertising mDNS service",
                        metadata: ["service": "\(instance)", "interface": "\(interfaceName)", "port": "\(target.hostPort)"])
                case .registered(let name):
                    log.warning(
                        "advertising mDNS service under another name, because the name is taken",
                        metadata: ["service": "\(instance)", "name": "\(name)", "interface": "\(interfaceName)"])
                case .failed(let code):
                    log.warning(
                        "failed to advertise mDNS service",
                        metadata: ["service": "\(instance)", "interface": "\(interfaceName)", "code": "\(code)"])
                }
            }
            state.registrations[key(for: target)] = Registration(operation: operation, txt: txt)
        } catch {
            log.warning(
                "failed to advertise mDNS service",
                metadata: ["service": "\(instance)", "interface": "\(interfaceName)", "error": "\(error)"])
        }
    }

    private func reportUnreachable(_ instance: ServiceInstance, state: Instance, port: UInt16) {
        guard !state.reportedUnreachable else {
            return
        }
        state.reportedUnreachable = true
        let published = configuration.publishedPorts.contains {
            ReflectionPolicy.hostPort(forContainerPort: port, transport: instance.type.transport, publishedPort: $0) != nil
        }
        log.info(
            published
                ? "not advertising mDNS service, because its published port is not reachable from another interface"
                : "not advertising mDNS service, because its port is not published",
            metadata: ["service": "\(instance)", "port": "\(port)/\(instance.type.transport.rawValue)"])
    }

    private func key(for target: ReflectionTarget) -> RegistrationKey {
        RegistrationKey(interfaceName: target.interface.name, interfaceIndex: target.interface.index, hostPort: target.hostPort)
    }
}
