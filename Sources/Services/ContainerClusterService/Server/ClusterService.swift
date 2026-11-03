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
import ContainerResource
import ContainerizationError
import Foundation
import Logging

public actor ClusterService {
    public typealias ContainerLister = @Sendable () async throws -> [ContainerSnapshot]

    private let store: ClusterStore
    private let listContainers: ContainerLister
    private let log: Logger

    public init(root: URL, listContainers: @escaping ContainerLister, log: Logger) {
        self.store = ClusterStore(root: root)
        self.listContainers = listContainers
        self.log = log
    }

    public func create(_ configuration: ClusterConfiguration) async throws {
        guard let existing = try store.load(name: configuration.name) else {
            try store.save(configuration)  // no suspension point between check and write
            return
        }
        try await ensureReplaceable(existing)
        log.info("replacing stale cluster record", metadata: ["name": "\(configuration.name)"])
        try store.save(configuration)
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
        let current = try store.load(name: record.name)
        guard current == nil || current == record else { throw alreadyExists }
    }

    public func get(name: String) async throws -> ClusterResource {
        guard let configuration = try store.load(name: name) else {
            throw ContainerizationError(.notFound, message: "cluster \(name) not found")
        }
        return Self.resources(configurations: [configuration], snapshots: try await listContainers())[0]
    }

    public func list() async throws -> [ClusterResource] {
        let configurations = store.loadAll(log: log)
        guard !configurations.isEmpty else { return [] }
        return Self.resources(configurations: configurations, snapshots: try await listContainers())
    }

    public func delete(name: String) throws {
        try store.remove(name: name)
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
