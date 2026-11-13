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
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Logging

private struct StartedWorker: Sendable {
    let provisioner: any NodeProvisioner
    let start: Date
}

extension ClusterBootstrapper {
    /// Builds a bootstrapper with a provisioner for each node in a stored cluster configuration.
    public init(configuration: ClusterConfiguration, containerSystemConfig: ContainerSystemConfig) throws {
        var controlPlane: LinuxNodeProvisioner?
        var workers: [LinuxNodeProvisioner] = []
        for node in configuration.nodes {
            let provisioner = try LinuxNodeProvisioner(
                name: node.name, clusterName: configuration.name, roles: node.roles,
                containerSystemConfig: containerSystemConfig)
            if node.name == configuration.name {
                controlPlane = provisioner
            } else {
                workers.append(provisioner)
            }
        }
        guard let controlPlane else {
            throw ContainerizationError(
                .internalError, message: "control plane \(configuration.name) not in cluster configuration")
        }
        self.init(
            name: configuration.name,
            kubernetesVersion: configuration.kubernetesVersion,
            cni: configuration.cni,
            fqdn: configuration.fqdn,
            sharedImageStore: configuration.sharedImageStore,
            controlPlane: controlPlane,
            workers: workers
        )
    }

    /// Starts the stopped nodes of an existing cluster, waits for it to be ready and refreshes its kubeconfig.
    ///
    /// - Parameters:
    ///   - configuration: The stored configuration of the cluster.
    ///   - progress: Called with a description at the start of each step.
    ///   - log: Logger for node and bootstrap steps.
    /// - Throws: The first error from a provisioner or start step.
    public func start(configuration: ClusterConfiguration, progress: @Sendable (String) -> Void, log: Logger) async throws {
        try validateNodeNames()

        let client = ContainerClient()
        let snapshots = try await client.list(
            filters: ContainerListFilters().withPlugin(ClusterHelper.pluginName))
        let toStart = try ClusterHelper.nodesToStart(configuration: configuration, snapshots: snapshots)

        let controlPlaneStarted = toStart.contains(name)
        let restartNames = ClusterHelper.workersToRestart(
            configuration: configuration, snapshots: snapshots, controlPlaneStarting: controlPlaneStarted)
        let startNames = toStart + restartNames

        try ClusterHelper.checkNodeStartPrerequisites(
            configuration: configuration, snapshots: snapshots, toStart: startNames,
            hostStoreSocketPath: ClusterHelper.hostStoreSocketPath)

        for workerName in restartNames {
            log.info("Stopping running worker to refresh the control-plane address", metadata: ["node": "\(workerName)"])
            try await client.stop(
                id: workerName,
                opts: ContainerStopOptions(timeoutInSeconds: ClusterHelper.nodeStopTimeoutSeconds, signal: nil))
        }

        let workersToStart = workers.filter { startNames.contains($0.name) }

        if controlPlaneStarted {
            progress("Starting control plane")
            let controlPlaneStart = Date()
            try await ClusterHelper.startNode(id: name, client: client)
            try await ClusterHelper.waitForNodeBooted(containerId: name, client: client, log: log)
            try await controlPlane.reapplyNetworkSettings(log: log)
            try await ClusterHelper.waitForAPIServer(containerId: name, client: client, log: log)
            try await ClusterHelper.waitForNodeLease(
                nodeName: name, clusterName: name, since: controlPlaneStart, client: client, log: log)
        } else {
            try await ClusterHelper.waitForAPIServer(containerId: name, client: client, log: log)
        }

        var startedWorkers: [StartedWorker] = []
        if !workersToStart.isEmpty {
            let controlPlaneAddress = try await controlPlane.address(log: log)
            let clusterName = name
            startedWorkers = try await withThrowingTaskGroup(of: StartedWorker.self) { group in
                for worker in workersToStart {
                    progress("Starting worker \(worker.name)")
                    group.addTask {
                        let workerStart = Date()
                        try await ClusterHelper.startNode(id: worker.name, client: client)
                        try await ClusterHelper.waitForNodeBooted(containerId: worker.name, client: client, log: log)
                        try await worker.reapplyNetworkSettings(log: log)
                        if configuration.fqdn == nil {
                            try await worker.setControlPlaneHost(host: clusterName, address: controlPlaneAddress, log: log)
                        }
                        return StartedWorker(provisioner: worker, start: workerStart)
                    }
                }
                var results: [StartedWorker] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }
        }

        for worker in startedWorkers {
            try await ClusterHelper.waitForNodeLease(
                nodeName: worker.provisioner.name, clusterName: name, since: worker.start, client: client, log: log)
            if ClusterHelper.skipsCNI(cni: configuration.cni) {
                try await worker.provisioner.waitForRegistered(log: log)
            } else {
                try await worker.provisioner.waitForReady(log: log)
            }
        }

        progress("Waiting for cluster to be ready")
        if ClusterHelper.skipsCNI(cni: configuration.cni) {
            try await ClusterHelper.waitForAPIServer(containerId: name, client: client, log: log)
        } else {
            try await ClusterHelper.waitForReady(containerId: name, client: client, log: log)
            let currentAddress = try await controlPlane.address(log: log)
            try await ClusterHelper.waitForClusterDNS(
                clusterName: name, controlPlaneAddress: currentAddress, client: client, log: log)
            if ClusterHelper.usesDefaultCNI(cni: configuration.cni) && configuration.nodes.count > 1 {
                try await ClusterHelper.waitForPodNetworkRoutes(
                    clusterName: name, expectedNodeCount: configuration.nodes.count, client: client, log: log)
            }
        }

        progress("Writing kubeconfig")
        do {
            let rawConfig = try await ClusterHelper.fetchConfig(containerId: name, client: client, log: log)
            let kubeConfig = try await ClusterHelper.transformConfig(
                rawConfig, containerId: name, fqdn: configuration.fqdn, client: client)
            try ClusterHelper.mergeConfig(kubeConfig, containerId: name, setCurrentContext: true, log: log)
        } catch {
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
            log.info("cluster is running; use 'container cluster write-config --name \(name)' to write the kubeconfig")
        }
    }
}
