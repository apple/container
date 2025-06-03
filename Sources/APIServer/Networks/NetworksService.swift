//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerClient
import ContainerNetworkService
import ContainerPersistence
import ContainerPlugin
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging

actor NetworksService {
    private let resourceRoot: URL
    // FIXME: remove qualifier once we can update Containerization dependency.
    private let store: ContainerPersistence.FilesystemEntityStore<NetworkConfiguration>
    private let pluginLoader: PluginLoader
    private let log: Logger
    private let networkPlugin: Plugin

    private var networkStates = [String: NetworkState]()
    private var busyNetworks = Set<String>()

    public init(pluginLoader: PluginLoader, resourceRoot: URL, log: Logger) async throws {
        try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
        self.resourceRoot = resourceRoot
        self.store = try FilesystemEntityStore<NetworkConfiguration>(path: resourceRoot, type: "network", log: log)
        self.pluginLoader = pluginLoader
        self.log = log

        let networkPlugin =
            pluginLoader
            .findPlugins()
            .filter { $0.hasType(.network) }
            .first
        guard let networkPlugin else {
            throw ContainerizationError(.internalError, message: "cannot find network plugin")
        }
        self.networkPlugin = networkPlugin

        let configurations = try await store.list()
        for configuration in configurations {
            do {
                try await registerService(configuration: configuration)
            } catch {
                log.error(
                    "failed to start network",
                    metadata: [
                        "id": "\(configuration.id)"
                    ])
            }

            let client = NetworkClient(id: configuration.id)
            let networkState = try await client.state()
            networkStates[configuration.id] = networkState
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
        return networkStates.reduce(into: [NetworkState]()) {
            $0.append($1.value)
        }
    }

    /// Create a new network from the provided configuration.
    public func create(configuration: NetworkConfiguration) async throws -> NetworkState {
        guard !busyNetworks.contains(configuration.id) else {
            throw ContainerizationError(.exists, message: "network \(configuration.id) has a pending operation")
        }

        busyNetworks.insert(configuration.id)
        defer { busyNetworks.remove(configuration.id) }

        log.info(
            "network service: create",
            metadata: [
                "id": "\(configuration.id)"
            ])

        // Ensure the network doesn't already exist.
        guard networkStates[configuration.id] == nil else {
            throw ContainerizationError(.exists, message: "network \(configuration.id) already exists")
        }

        // Create and start the network.
        try await registerService(configuration: configuration)
        let client = NetworkClient(id: configuration.id)
        let networkState = try await client.state()
        networkStates[configuration.id] = networkState

        // Persist the configuration data.
        do {
            try await store.create(configuration)
            return networkState
        } catch {
            networkStates.removeValue(forKey: configuration.id)
            do {
                try pluginLoader.deregisterWithLaunchd(plugin: networkPlugin, instanceId: configuration.id)
            } catch {
                log.error(
                    "failed to deregister network service after failed creation",
                    metadata: [
                        "id": "\(configuration.id)",
                        "error": "\(error.localizedDescription)",
                    ])
            }

            throw error
        }
    }

    /// Delete a network.
    public func delete(id: String) async throws {
        guard !busyNetworks.contains(id) else {
            throw ContainerizationError(.exists, message: "network \(id) has a pending operation")
        }

        busyNetworks.insert(id)
        defer { busyNetworks.remove(id) }

        log.info(
            "network service: delete",
            metadata: [
                "id": "\(id)"
            ])
        if id == ClientNetwork.defaultNetworkName {
            throw ContainerizationError(.invalidArgument, message: "cannot delete system subnet \(ClientNetwork.defaultNetworkName)")
        }

        guard let networkState = networkStates[id] else {
            throw ContainerizationError(.notFound, message: "no network for id \(id)")
        }

        guard case .running = networkState else {
            throw ContainerizationError(.invalidState, message: "cannot delete subnet \(id) in state \(networkState.state)")
        }

        let client = NetworkClient(id: id)
        guard try await client.disableAllocator() else {
            throw ContainerizationError(.invalidState, message: "cannot delete subnet \(id) with containers attached")
        }

        defer { networkStates.removeValue(forKey: id) }
        do {
            try pluginLoader.deregisterWithLaunchd(plugin: networkPlugin, instanceId: id)
        } catch {
            log.error(
                "failed to deregister network service after failed creation",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error.localizedDescription)",
                ])
        }

        do {
            try await store.delete(id)
        } catch {
            throw ContainerizationError(.notFound, message: error.localizedDescription)
        }
    }

    /// Perform a hostname lookup on all networks.
    public func lookup(hostname: String) async throws -> Attachment? {
        for id in networkStates.keys {
            let client = NetworkClient(id: id)
            guard let allocation = try await client.lookup(hostname: hostname) else {
                continue
            }
            return allocation
        }
        return nil
    }

    private func registerService(configuration: NetworkConfiguration) async throws {
        guard configuration.mode == .nat else {
            throw ContainerizationError(.invalidArgument, message: "unsupported network mode \(configuration.mode.rawValue)")
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

        if let subnet = (try configuration.subnet.map { try CIDRAddress($0) }) {
            var existingCidrs: [CIDRAddress] = []
            for networkState in networkStates.values {
                if case .running(_, let status) = networkState {
                    existingCidrs.append(try CIDRAddress(status.address))
                }
            }
            let overlap = existingCidrs.first { $0.overlaps(cidr: subnet) }
            if let overlap {
                throw ContainerizationError(.exists, message: "subnet \(subnet) overlaps an existing network with subnet \(overlap)")
            }

            args += ["--subnet", subnet.description]
        }

        try await pluginLoader.registerWithLaunchd(
            plugin: networkPlugin,
            rootURL: store.entityUrl(configuration.id),
            args: args,
            instanceId: configuration.id
        )
    }
}
