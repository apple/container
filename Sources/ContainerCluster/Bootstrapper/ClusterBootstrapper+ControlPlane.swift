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
import ContainerPlugin
import ContainerizationError
import Foundation
import Logging

extension ClusterBootstrapper {
    func bootstrapControlPlane(
        nodeID: String, apiServerSANs: [String], advertiseAddress: String,
        schedulable: Bool, client: ContainerClient, log: Logger
    ) async throws {
        let configYAML = Self.initConfigYAML(
            kubernetesVersion: kubernetesVersion, advertiseAddress: advertiseAddress, certSANs: apiServerSANs,
            sharedImageStore: sharedImageStore)
        var r = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "cat > /etc/kubernetes/kubeadm-config.yaml <<'EOF'\n\(configYAML)\nEOF"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "write kubeadm config failed on \(nodeID): \(r.output)")
        }

        log.info("Running kubeadm init", metadata: ["node": "\(nodeID)"])
        r = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: ClusterHelper.kubeadmPath,
            arguments: [
                "init", "--config", "/etc/kubernetes/kubeadm-config.yaml",
                "--ignore-preflight-errors", ClusterHelper.ignorePreflightErrors,
            ],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm init failed on \(nodeID): \(r.output)")
        }

        r = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "mkdir -p /root/.kube && cp \(ClusterHelper.kubeconfigPath) /root/.kube/config"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "failed to install root kubeconfig on \(nodeID): \(r.output)")
        }

        if schedulable {
            log.info("Removing control-plane taint for single-node scheduling", metadata: ["node": "\(nodeID)"])
            let taintCode = try await ClusterHelper.runProbe(
                client: client, containerId: nodeID,
                arguments: ["taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"])
            guard taintCode == 0 else {
                throw ContainerizationError(.internalError, message: "failed to remove control-plane taint on \(nodeID)")
            }
        }

        if skipCNI {
            log.info("Skipping CNI installation", metadata: ["node": "\(nodeID)"])
        } else {
            log.info("Applying CNI manifest", metadata: ["node": "\(nodeID)"])
            let manifest = try await Self.loadCNIManifest(path: cni, log: log)
            let apply = "\(ClusterHelper.kubeconfigEnv) kubectl apply -f - <<'EOF'\n\(manifest)\nEOF"
            r = try await ClusterHelper.execCapture(
                containerId: nodeID, executable: "/bin/sh",
                arguments: ["-c", apply], client: client)
            guard r.code == 0 else {
                throw ContainerizationError(.internalError, message: "apply CNI failed on \(nodeID): \(r.output)")
            }
        }
    }

    func createJoinToken(nodeID: String, client: ContainerClient) async throws -> (token: String, caCertHash: String) {
        let (code, output) = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: ClusterHelper.kubeadmPath,
            arguments: ["token", "create", "--print-join-command"],
            client: client)
        guard code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm token create failed on \(nodeID): \(output)")
        }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard let tokenIdx = parts.firstIndex(of: "--token"), tokenIdx + 1 < parts.count,
            let hashIdx = parts.firstIndex(of: "--discovery-token-ca-cert-hash"), hashIdx + 1 < parts.count
        else {
            throw ContainerizationError(.internalError, message: "could not parse join command output from kubeadm on \(nodeID)")
        }
        return (token: parts[tokenIdx + 1], caCertHash: parts[hashIdx + 1])
    }

    static func loadCNIManifest(path: String?, log: Logger) async throws -> String {
        if let path {
            do {
                return try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw ContainerizationError(.invalidArgument, message: "failed to read CNI manifest at \(path): \(error)")
            }
        }
        return try await loadKindnetManifest(log: log)
    }

    private static func loadKindnetManifest(log: Logger) async throws -> String {
        let url = try await ClusterHelper.pluginResourceURL(log: log).appendingPathComponent("kindnet.yaml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "kindnet manifest resource missing at \(url.path)")
        }
        return contents
    }

    static func initConfigYAML(
        kubernetesVersion: String, advertiseAddress: String, certSANs: [String], sharedImageStore: Bool
    ) -> String {
        let sans = certSANs.map { "  - \($0)" }.joined(separator: "\n")
        var kubelet = """
            apiVersion: kubelet.config.k8s.io/v1beta1
            kind: KubeletConfiguration
            cgroupDriver: systemd
            failSwapOn: false
            """
        if sharedImageStore {
            kubelet += "\nimageServiceEndpoint: unix://\(ClusterHelper.nodeImageServiceSocketPath)"
        }
        return """
            apiVersion: kubeadm.k8s.io/v1beta4
            kind: InitConfiguration
            localAPIEndpoint:
              advertiseAddress: \(advertiseAddress)
              bindPort: 6443
            nodeRegistration:
              criSocket: unix:///run/containerd/containerd.sock
            ---
            apiVersion: kubeadm.k8s.io/v1beta4
            kind: ClusterConfiguration
            kubernetesVersion: \(kubernetesVersion)
            networking:
              podSubnet: \(ClusterHelper.podSubnet)
            apiServer:
              certSANs:
            \(sans)
            ---
            \(kubelet)
            """
    }
}
