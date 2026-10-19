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
import ContainerizationError
import Logging

/// Bootstraps a Kubernetes cluster out of nodes managed by `NodeProvisioner`s.
///
/// The bootstrapper owns the cluster-level sequence: starting the control plane, running
/// kubeadm init, joining workers, waiting for readiness and writing the kubeconfig.
/// The caller decides the topology by supplying the provisioners; the bootstrapper delegates
/// the per-node lifecycle to them. `NodeProvisioner` is the extension point for new kinds
/// of node.
public struct ClusterBootstrapper: Sendable {
    let name: String
    let kubernetesVersion: String
    let cni: String?
    let fqdn: String?
    let controlPlane: any NodeProvisioner
    let workers: [any NodeProvisioner]

    /// - Parameters:
    ///   - name: Cluster name, also the control-plane node's name.
    ///   - kubernetesVersion: Exact Kubernetes version for kubeadm, e.g. `v1.35.5`. It must match the version installed on the nodes.
    ///   - cni: Path to a CNI manifest, `"NONE"` to skip installing one, or nil for the default.
    ///   - fqdn: DNS name for the API server, added to its certificate SANs.
    ///   - controlPlane: Provisioner for the control-plane node, whose name must be `name`. Its roles include
    ///     `StandardRoles.worker` when the cluster has no separate workers.
    ///   - workers: Provisioners for the worker nodes to join, in order. Each must be named
    ///     `K8sHelper.workerName(cluster:index:)`, which `list` and `delete` rely on.
    public init(
        name: String,
        kubernetesVersion: String,
        cni: String?,
        fqdn: String?,
        controlPlane: any NodeProvisioner,
        workers: [any NodeProvisioner]
    ) {
        self.name = name
        self.kubernetesVersion = kubernetesVersion
        self.cni = cni
        self.fqdn = fqdn
        self.controlPlane = controlPlane
        self.workers = workers
    }

    var skipCNI: Bool { cni?.uppercased() == K8sHelper.noCNIName }

    /// `list` and `delete` find nodes by name, and the bootstrapper execs into the control plane
    /// by cluster name, so the provisioners' names must follow the cluster's naming scheme.
    private func validateNodeNames() throws {
        guard controlPlane.name == name else {
            throw ContainerizationError(
                .invalidArgument,
                message: "control-plane node name \(controlPlane.name) must match cluster name \(name)")
        }
        for (index, worker) in workers.enumerated() {
            let expected = K8sHelper.workerName(cluster: name, index: index + 1)
            guard worker.name == expected else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "worker node name \(worker.name) must be \(expected)")
            }
        }
    }

    /// Creates the cluster and merges its kubeconfig. On failure, tears down every
    /// node this bootstrapper started and removes the kubeconfig entries before re-throwing.
    ///
    /// - Parameters:
    ///   - progress: Called with a description at the start of each step.
    ///   - log: Logger for node and bootstrap steps.
    /// - Throws: The first error from a provisioner or bootstrap step, after cleanup.
    public func create(progress: @Sendable (String) -> Void, log: Logger) async throws {
        let provisioner = controlPlane
        try validateNodeNames()

        progress("Starting cluster")
        try await provisioner.provision(log: log)

        let client = ContainerClient()
        var startedWorkers: [any NodeProvisioner] = []
        do {
            let vmIP = try await provisioner.address(log: log)
            var sans = ["127.0.0.1"]
            if let fqdn { sans.append(contentsOf: [vmIP, fqdn]) }

            progress("Running kubeadm init")
            try await bootstrapControlPlane(
                nodeID: name, apiServerSANs: sans, advertiseAddress: vmIP,
                schedulable: provisioner.roles.contains(StandardRoles.worker),
                client: client, log: log)

            if !workers.isEmpty {
                let (token, caCertHash) = try await createJoinToken(nodeID: name, client: client)
                let controlPlaneEndpoint = "\(vmIP):\(K8sHelper.clusterContainerPort)"
                for workerProvisioner in workers {
                    progress("Joining worker \(workerProvisioner.name)")
                    try await workerProvisioner.provision(log: log)
                    startedWorkers.append(workerProvisioner)
                    try await workerProvisioner.join(
                        controlPlaneEndpoint: controlPlaneEndpoint,
                        token: token, caCertHash: caCertHash, log: log)
                    if skipCNI {
                        try await workerProvisioner.waitForRegistered(log: log)
                    } else {
                        try await workerProvisioner.waitForReady(log: log)
                    }
                }
            }

            if skipCNI {
                progress("Waiting for API server")
                try await K8sHelper.waitForAPIServer(containerId: name, client: client, log: log)
            } else {
                progress("Waiting for cluster to be ready")
                try await K8sHelper.waitForReady(containerId: name, client: client, log: log)
            }

            progress("Writing kubeconfig")
            let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
            let kubeConfig = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
            do {
                try K8sHelper.mergeConfig(kubeConfig, containerId: name, setCurrentContext: true, log: log)
            } catch {
                log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
                log.info("cluster is running; use 'container k8s write-config --name \(name)' to write the kubeconfig")
            }
        } catch {
            for workerProvisioner in startedWorkers {
                try? await workerProvisioner.teardown(log: log)
            }
            try? await provisioner.teardown(log: log)
            try? K8sHelper.removeConfig(containerId: name, log: log)
            throw error
        }
    }
}
