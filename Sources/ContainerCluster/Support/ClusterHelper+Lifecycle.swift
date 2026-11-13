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
import ContainerResource
import ContainerizationError
import Foundation
import SystemPackage

extension ClusterHelper {
    // MARK: - Node selection

    /// Names of configured nodes that are not running, in configuration order.
    /// Throws if a configured node has no container.
    static func nodesToStart(configuration: ClusterConfiguration, snapshots: [ContainerSnapshot]) throws -> [String] {
        var names: [String] = []
        for node in configuration.nodes {
            guard let snapshot = snapshots.first(where: { $0.configuration.id == node.name }) else {
                throw ContainerizationError(
                    .notFound,
                    message: "node container \(node.name) not found; delete and re-create cluster \(configuration.name)")
            }
            if snapshot.status != .running {
                names.append(node.name)
            }
        }
        return names
    }

    /// Names of configured nodes that are running, in configuration order.
    static func nodesToStop(configuration: ClusterConfiguration, snapshots: [ContainerSnapshot]) -> [String] {
        var names: [String] = []
        for node in configuration.nodes {
            guard let snapshot = snapshots.first(where: { $0.configuration.id == node.name }) else {
                continue
            }
            if snapshot.status == .running {
                names.append(node.name)
            }
        }
        return names
    }

    /// Names of running workers to restart so they pick up the new control-plane address.
    /// Empty unless the control plane is starting and the cluster has no fqdn.
    static func workersToRestart(
        configuration: ClusterConfiguration, snapshots: [ContainerSnapshot], controlPlaneStarting: Bool
    ) -> [String] {
        guard controlPlaneStarting, configuration.fqdn == nil else {
            return []
        }
        var names: [String] = []
        for node in configuration.nodes where node.name != configuration.name {
            guard let snapshot = snapshots.first(where: { $0.configuration.id == node.name }) else {
                continue
            }
            if snapshot.status == .running {
                names.append(node.name)
            }
        }
        return names
    }

    // MARK: - Node start

    /// Checks the host store socket and the virtiofs mount sources of the nodes in `toStart`.
    static func checkNodeStartPrerequisites(
        configuration: ClusterConfiguration, snapshots: [ContainerSnapshot], toStart: [String],
        hostStoreSocketPath: FilePath
    ) throws {
        if configuration.sharedImageStore {
            try checkHostStoreSocket(path: hostStoreSocketPath)
        }
        for nodeName in toStart {
            guard let snapshot = snapshots.first(where: { $0.configuration.id == nodeName }) else {
                throw ContainerizationError(.notFound, message: "node container \(nodeName) not found")
            }
            for mount in snapshot.configuration.mounts where mount.isVirtiofs {
                guard FileManager.default.fileExists(atPath: mount.source) else {
                    throw ContainerizationError(.invalidState, message: "mount source path '\(mount.source)' does not exist")
                }
            }
        }
    }

    /// Throws if the host store socket does not exist.
    static func checkHostStoreSocket(path: FilePath) throws {
        guard FileManager.default.fileExists(atPath: path.string) else {
            throw ContainerizationError(
                .notFound,
                message: "host store socket \(path) not found; is the cluster-hoststore plugin installed and running?")
        }
    }

    /// Boots a node container detached. Stops the container if the start fails.
    static func startNode(id: String, client: ContainerClient) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        do {
            let process = try await client.bootstrap(id: id, stdio: io.stdio)
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? await client.stop(id: id)
            throw error
        }
    }
}
