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

import ContainerAPIClient
import ContainerNetworkServiceClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging

public actor NetworksService {
    struct NetworkServiceState {
        var networkState: NetworkState
        var client: NetworkClient
    }

    private let pluginLoader: PluginLoader
    private let resourceRoot: URL
    private let containersService: ContainersService
    private let log: Logger

    private let store: FilesystemEntityStore<NetworkConfiguration>
    private let networkPlugins: [Plugin]
    private var busyNetworks = Set<String>()

    private let stateLock = AsyncLock()
    private var serviceStates = [String: NetworkServiceState]()

    public init(
        pluginLoader: PluginLoader,
        resourceRoot: URL,
        containersService: ContainersService,
        log: Logger
    ) async throws {
        self.pluginLoader = pluginLoader
        self.resourceRoot = resourceRoot
        self.containersService = containersService
        self.log = log

        try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
        self.store = try FilesystemEntityStore<NetworkConfiguration>(
            path: resourceRoot,
            type: "network",
            log: log
        )

        let networkPlugins =
            pluginLoader
            .findPlugins()
            .filter { $0.hasType(.network) }
        guard !networkPlugins.isEmpty else {
            throw ContainerizationError(.internalError, message: "cannot find any plugins with type network")
        }
        self.networkPlugins = networkPlugins

        let configurations = try await store.list()
        for configuration in configurations {
            do {
                try await registerService(configuration: configuration)
            } catch {
                log.error(
                    "failed to start network: \(error)",
                    metadata: [
                        "id": "\(configuration.id)"
                    ])
            }

            let client = Self.getClient(configuration: configuration)
            var networkState = try await client.state()

            // FIXME: Temporary workaround for persisted configuration being overwritten
            // by what comes back from the network helper, which messes up creationDate.
            switch networkState {
            case .created(_):
                networkState = NetworkState.created(configuration)
            case .running(_, let status):
                networkState = NetworkState.running(configuration, status)
            }

            let state = NetworkServiceState(
                networkState: networkState,
                client: client
            )

            serviceStates[configuration.id] = state

            guard case .running = networkState else {
                log.error(
                    "network failed to start",
                    metadata: [
                        "id": "\(configuration.id)",
                        "state": "\(networkState.state)",
                    ])
                return
            }
        }
    }

    /// List all networks registered with the service.
    public func list() async throws -> [NetworkState] {
        log.info("network service: list")
        return serviceStates.reduce(into: [NetworkState]()) {
            $0.append($1.value.networkState)
        }
    }

    /// Create a new network from the provided configuration.
    public func create(configuration: NetworkConfiguration) async throws -> NetworkState {
        log.info(
            "network service: create",
            metadata: [
                "id": "\(configuration.id)"
            ])

        //Ensure that the network is not named "none"
        if configuration.id == ClientNetwork.noNetworkName {
            throw ContainerizationError(.unsupported, message: "network \(configuration.id) is not a valid name")
        }

        // Ensure nobody is manipulating the network already.
        guard !busyNetworks.contains(configuration.id) else {
            throw ContainerizationError(.exists, message: "network \(configuration.id) has a pending operation")
        }

        busyNetworks.insert(configuration.id)
        defer { busyNetworks.remove(configuration.id) }

        // Ensure the network doesn't already exist.
        return try await self.stateLock.withLock { _ in
            guard await self.serviceStates[configuration.id] == nil else {
                throw ContainerizationError(.exists, message: "network \(configuration.id) already exists")
            }

            // Create and start the network.
            try await self.registerService(configuration: configuration)
            let client = Self.getClient(configuration: configuration)

            // Ensure the network is running, and set up the persistent network state
            // using our configuration data, as the one from the helper doesn't include
            // metadata.
            guard case .running(_, let status) = try await client.state() else {
                throw ContainerizationError(.invalidState, message: "network \(configuration.id) failed to start")
            }
            let networkState: NetworkState = .running(configuration, status)
            let serviceState = NetworkServiceState(networkState: networkState, client: client)
            await self.setServiceState(key: configuration.id, value: serviceState)

            // Persist the configuration data.
            do {
                try await self.store.create(configuration)
                return networkState
            } catch {
                await self.removeServiceState(key: configuration.id)
                do {
                    try await self.deregisterService(configuration: configuration)
                } catch {
                    self.log.error(
                        "failed to deregister network service after failed creation",
                        metadata: [
                            "id": "\(configuration.id)",
                            "error": "\(error.localizedDescription)",
                        ])
                }
                throw error
            }
        }
    }

    /// Delete a network.
    public func delete(id: String) async throws {
        // check actor busy state
        guard !busyNetworks.contains(id) else {
            throw ContainerizationError(.exists, message: "network \(id) has a pending operation")
        }

        // make actor state busy for this network
        busyNetworks.insert(id)
        defer { busyNetworks.remove(id) }

        log.info(
            "network service: delete",
            metadata: [
                "id": "\(id)"
            ])

        // basic sanity checks on network itself
        if id == ClientNetwork.defaultNetworkName {
            throw ContainerizationError(.invalidArgument, message: "cannot delete system subnet \(ClientNetwork.defaultNetworkName)")
        }

        try await stateLock.withLock { _ in
            guard let serviceState = await self.serviceStates[id] else {
                throw ContainerizationError(.notFound, message: "no network for id \(id)")
            }

            guard case .running(let netConfig, _) = serviceState.networkState else {
                throw ContainerizationError(.invalidState, message: "cannot delete subnet \(id) in state \(serviceState.networkState.state)")
            }

            // prevent container operations while we atomically check and delete
            try await self.containersService.withContainerList { containers in
                // find all containers that refer to the network
                var referringContainers = Set<String>()
                for container in containers {
                    for attachmentConfiguration in container.configuration.networks {
                        if attachmentConfiguration.network == id {
                            referringContainers.insert(container.configuration.id)
                            break
                        }
                    }
                }

                // bail if any referring containers
                guard referringContainers.isEmpty else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "cannot delete subnet \(id) with referring containers: \(referringContainers.joined(separator: ", "))"
                    )
                }

                // disable the allocator so nothing else can attach
                // TODO: remove this from the network helper later, not necesssary now that withContainerList is here
                guard try await serviceState.client.disableAllocator() else {
                    throw ContainerizationError(.invalidState, message: "cannot delete subnet \(id) because the IP allocator cannot be disabled with active containers")
                }

                // start network deletion, this is the last place we'll want to throw
                do {
                    try await self.deregisterService(configuration: netConfig)
                } catch {
                    self.log.error(
                        "failed to deregister network service",
                        metadata: [
                            "id": "\(id)",
                            "error": "\(error.localizedDescription)",
                        ])
                }

                // deletion is underway, do not throw anything now
                do {
                    try await self.store.delete(id)
                } catch {
                    self.log.error(
                        "failed to delete network from configuration store",
                        metadata: [
                            "id": "\(id)",
                            "error": "\(error.localizedDescription)",
                        ])
                }
            }

            // having deleted successfully, remove the runtime state
            await self.removeServiceState(key: id)
        }
    }

    /// Perform a hostname lookup on all networks.
    public func lookup(hostname: String) async throws -> Attachment? {
        try await self.stateLock.withLock { _ in
            for state in await self.serviceStates.values {
                guard let allocation = try await state.client.lookup(hostname: hostname) else {
                    continue
                }
                return allocation
            }
            return nil
        }
    }

    public func allocate(id: String, hostname: String, macAddress: String?) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        guard let serviceState = serviceStates[id] else {
            throw ContainerizationError(.notFound, message: "no network for id \(id)")
        }
        return try await serviceState.client.allocate(hostname: hostname, macAddress: macAddress)
    }

    public func deallocate(id: String, hostname: String) async throws {
        guard let serviceState = serviceStates[id] else {
            throw ContainerizationError(.notFound, message: "no network for id \(id)")
        }
        return try await serviceState.client.deallocate(hostname: hostname)
    }

    public func lookup(id: String, hostname: String) async throws -> Attachment? {
        guard let serviceState = serviceStates[id] else {
            throw ContainerizationError(.notFound, message: "no network for id \(id)")
        }
        return try await serviceState.client.lookup(hostname: hostname)
    }

    public func disableAllocator(id: String) async throws -> Bool {
        guard let serviceState = serviceStates[id] else {
            throw ContainerizationError(.notFound, message: "no network for id \(id)")
        }
        return try await serviceState.client.disableAllocator()
    }

    private static func getClient(configuration: NetworkConfiguration) -> NetworkClient {
        NetworkClient(id: configuration.id, plugin: configuration.pluginInfo.plugin)
    }

    private func registerService(configuration: NetworkConfiguration) async throws {
        guard configuration.mode == .nat else {
            throw ContainerizationError(.invalidArgument, message: "unsupported network mode \(configuration.mode.rawValue)")
        }

        guard let networkPlugin = self.networkPlugins.first(where: { $0.name == configuration.pluginInfo.plugin }) else {
            throw ContainerizationError(
                .notFound,
                message: "unable to locate network plugin \(configuration.pluginInfo.plugin)"
            )
        }

        guard let serviceIdentifier = networkPlugin.getMachService(instanceId: configuration.id, type: .network) else {
            throw ContainerizationError(.invalidArgument, message: "unsupported network mode \(configuration.mode.rawValue)")
        }
        var args = [
            "start",
            "--id",
            configuration.id,
            "--service-identifier",
            serviceIdentifier,
        ]

        if let ipv4Subnet = configuration.ipv4Subnet {
            var existingCidrs: [CIDRv4] = []
            for serviceState in serviceStates.values {
                if case .running(_, let status) = serviceState.networkState {
                    existingCidrs.append(status.ipv4Subnet)
                }
            }
            let overlap = existingCidrs.first {
                $0.contains(ipv4Subnet.lower)
                    || $0.contains(ipv4Subnet.upper)
                    || ipv4Subnet.contains($0.lower)
                    || ipv4Subnet.contains($0.upper)
            }
            if let overlap {
                throw ContainerizationError(.exists, message: "IPv4 subnet \(ipv4Subnet) overlaps an existing network with subnet \(overlap)")
            }

            args += ["--subnet", ipv4Subnet.description]
        }

        if let ipv6Subnet = configuration.ipv6Subnet {
            var existingCidrs: [CIDRv6] = []
            for serviceState in serviceStates.values {
                if case .running(_, let status) = serviceState.networkState, let otherIPv6Subnet = status.ipv6Subnet {
                    existingCidrs.append(otherIPv6Subnet)
                }
            }
            let overlap = existingCidrs.first {
                $0.contains(ipv6Subnet.lower)
                    || $0.contains(ipv6Subnet.upper)
                    || ipv6Subnet.contains($0.lower)
                    || ipv6Subnet.contains($0.upper)
            }
            if let overlap {
                throw ContainerizationError(.exists, message: "IPv6 subnet \(ipv6Subnet) overlaps an existing network with subnet \(overlap)")
            }

            args += ["--subnet-v6", ipv6Subnet.description]
        }

        if let variant = configuration.pluginInfo.variant {
            args += ["--variant", variant]
        }

        try await pluginLoader.registerWithLaunchd(
            plugin: networkPlugin,
            pluginStateRoot: store.entityUrl(configuration.id),
            args: args,
            instanceId: configuration.id
        )
    }

    private func deregisterService(configuration: NetworkConfiguration) async throws {
        guard let networkPlugin = self.networkPlugins.first(where: { $0.name == configuration.pluginInfo.plugin }) else {
            throw ContainerizationError(
                .notFound,
                message: "unable to locate network plugin \(configuration.pluginInfo.plugin)"
            )
        }
        try self.pluginLoader.deregisterWithLaunchd(plugin: networkPlugin, instanceId: configuration.id)
    }
}

extension NetworksService {
    private func removeServiceState(key: String) {
        self.serviceStates.removeValue(forKey: key)
    }

    private func setServiceState(key: String, value: NetworkServiceState) {
        self.serviceStates[key] = value
    }
}
