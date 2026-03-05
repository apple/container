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
    private let debugHelpers: Bool

    private let store: FilesystemEntityStore<NetworkConfiguration>
    private let networkPlugins: [Plugin]
    private var busyNetworks = Set<String>()

    private let stateLock = AsyncLock()
    private var serviceStates = [String: NetworkServiceState]()

    public init(
        pluginLoader: PluginLoader,
        resourceRoot: URL,
        containersService: ContainersService,
        log: Logger,
        debugHelpers: Bool = false,
    ) async throws {
        self.pluginLoader = pluginLoader
        self.resourceRoot = resourceRoot
        self.containersService = containersService
        self.log = log
        self.debugHelpers = debugHelpers

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
        for var configuration in configurations {
            // Ensure the network with id "default" is marked as builtin.
            if configuration.id == ClientNetwork.defaultNetworkName {
                let role = configuration.labels[ResourceLabelKeys.role]
                if role == nil || role != ResourceRoleValues.builtin {
                    configuration.labels[ResourceLabelKeys.role] = ResourceRoleValues.builtin
                    try await store.update(configuration)
                }
            }

            // Ensure that the network always has plugin information.
            // Before this field was added, the code always assumed we were using the
            // container-network-vmnet network plugin, so it should be safe to fallback to that
            // if no info was found in an on disk configuration.
            if configuration.pluginInfo == nil {
                configuration.pluginInfo = NetworkPluginInfo(plugin: "container-network-vmnet")
                try await store.update(configuration)
            }

            // Start up the network.
            do {
                try await registerService(configuration: configuration)
            } catch {
                log.error(
                    "failed to start network",
                    metadata: [
                        "id": "\(configuration.id)",
                        "error": "\(error)",
                    ])
            }

            // This call will normally take ~20-100ms to complete after service
            // registration, but on a fresh system (e.g. CI runner), it may take
            // 5 seconds or considerably more from the registration of this first
            // network service to its execution.
            let client = try Self.getClient(configuration: configuration)
            var networkState = try await client.state()

            // FIXME: Temporary workaround for persisted configuration being overwritten
            // by what comes back from the network helper, which messes up creationDate.
            // FIXME: Temporarily need to override the plugin information with the info from
            // the helper, so we can ensure that older networks get a variant value.
            var finalConfig = configuration
            switch networkState {
            case .created(let helperConfig):
                finalConfig.pluginInfo = helperConfig.pluginInfo
                networkState = NetworkState.created(finalConfig)
            case .running(let helperConfig, let status):
                finalConfig.pluginInfo = helperConfig.pluginInfo
                networkState = NetworkState.running(finalConfig, status)
            }

            let state = NetworkServiceState(
                networkState: networkState,
                client: client
            )

            serviceStates[finalConfig.id] = state

            guard case .running = networkState else {
                log.error(
                    "network failed to start",
                    metadata: [
                        "id": "\(finalConfig.id)",
                        "state": "\(networkState.state)",
                    ])
                return
            }
        }
    }

    /// List all networks registered with the service.
    public func list() async throws -> [NetworkState] {
        log.debug("NetworksService: enter", metadata: ["func": "\(#function)"])
        defer { log.debug("NetworksService: exit", metadata: ["func": "\(#function)"]) }

        return serviceStates.reduce(into: [NetworkState]()) {
            $0.append($1.value.networkState)
        }
    }

    /// Create a new network from the provided configuration.
    public func create(configuration: NetworkConfiguration) async throws -> NetworkState {
        log.debug(
            "NetworksService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(configuration.id)",
            ]
        )
        defer {
            log.debug(
                "NetworksService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(configuration.id)",
                ]
            )
        }

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
            let client = try Self.getClient(configuration: configuration)

            // Ensure the network is running, and set up the persistent network state
            // using our configuration data
            guard case .running(let helperConfig, let status) = try await client.state() else {
                throw ContainerizationError(.invalidState, message: "network \(configuration.id) failed to start")
            }
            var finalConfig = configuration
            finalConfig.pluginInfo = helperConfig.pluginInfo

            let networkState: NetworkState = .running(finalConfig, status)
            let serviceState = NetworkServiceState(networkState: networkState, client: client)
            await self.setServiceState(key: finalConfig.id, value: serviceState)

            // Persist the configuration data.
            do {
                try await self.store.create(finalConfig)
                return networkState
            } catch {
                await self.removeServiceState(key: finalConfig.id)
                do {
                    try await self.deregisterService(configuration: finalConfig)
                } catch {
                    self.log.error(
                        "failed to deregister network service after failed creation",
                        metadata: [
                            "id": "\(finalConfig.id)",
                            "error": "\(error.localizedDescription)",
                        ])
                }
                throw error
            }
        }
    }

    /// Delete a network.
    public func delete(id: String) async throws {
        log.debug(
            "NetworksService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "NetworksService: enter",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // check actor busy state
        guard !busyNetworks.contains(id) else {
            throw ContainerizationError(.exists, message: "network \(id) has a pending operation")
        }

        // make actor state busy for this network
        busyNetworks.insert(id)
        defer { busyNetworks.remove(id) }

        log.info(
            "deleting network",
            metadata: [
                "id": "\(id)"
            ]
        )

        try await stateLock.withLock { _ in
            guard let serviceState = await self.serviceStates[id] else {
                throw ContainerizationError(.notFound, message: "no network for id \(id)")
            }

            guard case .running(let netConfig, _) = serviceState.networkState else {
                throw ContainerizationError(.invalidState, message: "cannot delete network \(id) in state \(serviceState.networkState.state)")
            }

            // basic sanity checks on network itself
            if serviceState.networkState.isBuiltin {
                throw ContainerizationError(.invalidArgument, message: "cannot delete builtin network: \(id)")
            }

            // prevent container operations while we atomically check and delete
            try await self.containersService.withContainerList(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { containers in
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

    public func allocate(id: String, hostname: String, macAddress: MACAddress?) async throws -> AllocatedAttachment {
        guard let serviceState = serviceStates[id] else {
            throw ContainerizationError(.notFound, message: "no network for id \(id)")
        }
        guard let pluginInfo = serviceState.networkState.pluginInfo else {
            throw ContainerizationError(.internalError, message: "network \(id) missing plugin information")
        }
        let (attach, additionalData) = try await serviceState.client.allocate(hostname: hostname, macAddress: macAddress)
        return AllocatedAttachment(
            attachment: attach,
            additionalData: additionalData,
            pluginInfo: pluginInfo
        )
    }

    public func deallocate(attachment: Attachment) async throws {
        guard let serviceState = serviceStates[attachment.network] else {
            throw ContainerizationError(.notFound, message: "no network for id \(attachment.network)")
        }
        return try await serviceState.client.deallocate(hostname: attachment.hostname)
    }

    private static func getClient(configuration: NetworkConfiguration) throws -> NetworkClient {
        guard let pluginInfo = configuration.pluginInfo else {
            throw ContainerizationError(.internalError, message: "network \(configuration.id) missing plugin information")
        }
        return NetworkClient(id: configuration.id, plugin: pluginInfo.plugin)
    }

    private func registerService(configuration: NetworkConfiguration) async throws {
        guard configuration.mode == .nat || configuration.mode == .hostOnly else {
            throw ContainerizationError(.invalidArgument, message: "unsupported network mode \(configuration.mode.rawValue)")
        }

        guard let pluginInfo = configuration.pluginInfo else {
            throw ContainerizationError(.internalError, message: "network \(configuration.id) missing plugin information")
        }

        guard let networkPlugin = self.networkPlugins.first(where: { $0.name == pluginInfo.plugin }) else {
            throw ContainerizationError(
                .notFound,
                message: "unable to locate network plugin \(pluginInfo.plugin)"
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
            "--mode",
            configuration.mode.rawValue,
        ]
        if debugHelpers {
            args.append("--debug")
        }

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

        if let variant = configuration.pluginInfo?.variant {
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
        guard let pluginInfo = configuration.pluginInfo else {
            throw ContainerizationError(.internalError, message: "network \(configuration.id) missing plugin information")
        }
        guard let networkPlugin = self.networkPlugins.first(where: { $0.name == pluginInfo.plugin }) else {
            throw ContainerizationError(
                .notFound,
                message: "unable to locate network plugin \(pluginInfo.plugin)"
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
