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

import ContainerClusterServiceClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Logging
import SystemPackage

public actor ClusterService {
    public typealias ContainerLister = @Sendable () async throws -> [ContainerSnapshot]

    private let store: FilesystemEntityStore<ClusterConfiguration>
    private let listContainers: ContainerLister
    private let log: Logger

    /// - Parameter root: Directory holding one subdirectory per cluster. Created if missing.
    public init(root: FilePath, listContainers: @escaping ContainerLister, log: Logger) throws {
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        self.store = try FilesystemEntityStore(path: root, type: "clusters", log: log)
        self.listContainers = listContainers
        self.log = log
    }

    /// Records the cluster and returns it. No node containers exist yet, so every node is reported stopped.
    public func create(configuration: ClusterConfiguration) async throws -> ClusterResource {
        if let existing = try await store.retrieve(configuration.name) {
            try await ensureReplaceable(existing)
            log.info("replacing stale cluster record", metadata: ["name": "\(configuration.name)"])
            try await store.upsert(configuration)
        } else {
            try await store.create(configuration)
        }
        guard let cluster = Self.resources(configurations: [configuration], snapshots: []).first else {
            throw ContainerizationError(.internalError, message: "failed to build cluster \(configuration.name)")
        }
        return cluster
    }

    /// Throws `.exists` unless `record` is stale: none of its node containers exist any more (e.g. a `--rm` cluster).
    private func ensureReplaceable(_ record: ClusterConfiguration) async throws {
        let alreadyExists = ContainerizationError(
            .exists,
            message: "cluster \(record.name) already exists; run 'container cluster delete --name \(record.name)' to remove it")

        let liveContainerIDs = Set(try await listContainers().map { $0.configuration.id })
        let hasLiveNode = record.nodes.contains { liveContainerIDs.contains($0.name) }
        guard !hasLiveNode else { throw alreadyExists }

        // The actor may have been re-entered while awaiting; only replace the record we inspected.
        let current = try await store.retrieve(record.name)
        guard current == nil || current == record else { throw alreadyExists }
    }

    public func get(name: String) async throws -> ClusterResource {
        guard let configuration = try await store.retrieve(name) else {
            throw ContainerizationError(.notFound, message: "cluster \(name) not found")
        }
        let snapshots = try await listContainers()
        guard let cluster = Self.resources(configurations: [configuration], snapshots: snapshots).first else {
            throw ContainerizationError(.internalError, message: "failed to build cluster \(name)")
        }
        return cluster
    }

    public func list() async throws -> [ClusterResource] {
        let configurations = try await store.list()
        guard !configurations.isEmpty else { return [] }
        return Self.resources(configurations: configurations, snapshots: try await listContainers())
    }

    public func delete(name: String) async throws {
        guard ClusterResource.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "invalid cluster name \(name)")
        }
        guard try await store.retrieve(name) != nil else {
            throw ContainerizationError(.notFound, message: "cluster \(name) not found")
        }
        try await store.delete(name)
    }

    /// Derives each cluster's status from its stored configuration and the live container snapshots.
    static func resources(configurations: [ClusterConfiguration], snapshots: [ContainerSnapshot]) -> [ClusterResource] {
        let byID = Dictionary(snapshots.map { ($0.configuration.id, $0) }, uniquingKeysWith: { first, _ in first })
        return configurations.sorted { $0.name < $1.name }.map { config in
            let nodes = config.nodes.map { node -> ClusterNodeState in
                guard let snapshot = byID[node.name] else {
                    return ClusterNodeState(name: node.name, status: .stopped)
                }
                let addresses = snapshot.networks.map { $0.ipv4Address.address.description }
                let ports = snapshot.configuration.publishedPorts.map { "\($0.hostPort)->\($0.containerPort)" }
                return ClusterNodeState(
                    name: node.name, status: snapshot.status,
                    addresses: addresses.isEmpty ? nil : addresses,
                    ports: ports.isEmpty ? nil : ports)
            }
            let up = nodes.filter { $0.status == .running }.count
            let state: ClusterState = up == 0 ? .stopped : (up == nodes.count ? .running : .degraded)
            return ClusterResource(configuration: config, status: ClusterStatus(state: state, nodes: nodes))
        }
    }
}
