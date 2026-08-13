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
import ContainerizationOCI
import Foundation
import Logging

extension K8sHelper {

    public static func prepareNode(nodeID: String, client: ContainerClient, log: Logger) async throws {
        log.info("Preparing node", metadata: ["id": "\(nodeID)"])
        let result = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", nodePrepScript], client: client)
        guard result.code == 0 else {
            throw ContainerizationError(.internalError, message: "node prep failed on \(nodeID): \(result.output)")
        }
    }

    static func bootstrapControlPlane(
        nodeID: String, apiServerSANs: [String], advertiseAddress: String,
        schedulable: Bool, client: ContainerClient, log: Logger
    ) async throws {
        let configYAML = initConfigYAML(advertiseAddress: advertiseAddress, certSANs: apiServerSANs)
        var r = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "cat > /etc/kubernetes/kubeadm-config.yaml <<'EOF'\n\(configYAML)\nEOF"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "write kubeadm config failed on \(nodeID): \(r.output)")
        }

        log.info("Running kubeadm init", metadata: ["node": "\(nodeID)"])
        r = try await execCapture(
            containerId: nodeID, executable: kubeadmPath,
            arguments: [
                "init", "--config", "/etc/kubernetes/kubeadm-config.yaml",
                "--ignore-preflight-errors", ignorePreflightErrors,
            ],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm init failed on \(nodeID): \(r.output)")
        }

        r = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "mkdir -p /root/.kube && cp \(kubeconfigPath) /root/.kube/config"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "failed to install root kubeconfig on \(nodeID): \(r.output)")
        }

        if schedulable {
            log.info("Removing control-plane taint for single-node scheduling", metadata: ["node": "\(nodeID)"])
            _ = try await runProbe(
                client: client, containerId: nodeID,
                arguments: ["taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"])
        }

        log.info("Applying kindnet CNI", metadata: ["node": "\(nodeID)"])
        let manifest = try await loadKindnetManifest(log: log)
        let apply =
            "cat > /tmp/kindnet.yaml <<'EOF'\n\(manifest)\nEOF\n"
            + "\(kubeconfigEnv) kubectl apply -f /tmp/kindnet.yaml"
        r = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", apply], client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "apply CNI failed on \(nodeID): \(r.output)")
        }
    }

    static func createJoinToken(nodeID: String, client: ContainerClient) async throws -> (token: String, caCertHash: String) {
        let (code, output) = try await execCapture(
            containerId: nodeID, executable: kubeadmPath,
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

    private static func loadKindnetManifest(log: Logger) async throws -> String {
        let pluginLoader = try await Utility.createPluginLoader(log: log)
        guard let plugin = pluginLoader.findPlugin(forExecutable: CommandLine.executablePath),
            let resourceURL = plugin.resourceURL
        else {
            throw ContainerizationError(.internalError, message: "unable to locate k8s plugin installation or resources")
        }
        let url = resourceURL.appendingPathComponent("kindnet.yaml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "kindnet manifest resource missing at \(url.path)")
        }
        return contents
    }

    private static var nodePrepScript: String {
        """
        set -e
        mkdir -p /etc/containerd/conf.d
        cat > /etc/containerd/conf.d/native-snapshotter.toml <<'EOF'
        [plugins.'io.containerd.cri.v1.images']
          snapshotter = "native"
        EOF
        sysctl -w net.ipv4.ip_forward=1                 2>/dev/null || true
        sysctl -w net.bridge.bridge-nf-call-iptables=1  2>/dev/null || true
        sysctl -w net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
        systemctl restart containerd
        ctr -n k8s.io images tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1 2>/dev/null || true
        /usr/sbin/iptables-nft -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        /usr/sbin/iptables-nft -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        """
    }

    private static func initConfigYAML(advertiseAddress: String, certSANs: [String]) -> String {
        let sans = certSANs.map { "  - \($0)" }.joined(separator: "\n")
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
            kubernetesVersion: \(kubernetesVersion())
            networking:
              podSubnet: \(podSubnet)
            apiServer:
              certSANs:
            \(sans)
            ---
            apiVersion: kubelet.config.k8s.io/v1beta1
            kind: KubeletConfiguration
            cgroupDriver: systemd
            failSwapOn: false
            """
    }

    private static func kubernetesVersion() -> String {
        let nameAndTag = nodeImage.split(separator: "@").first.map(String.init) ?? nodeImage
        guard let ref = try? Reference.parse(nameAndTag), let tag = ref.tag else { return "v1.35" }
        return tag
    }
}
