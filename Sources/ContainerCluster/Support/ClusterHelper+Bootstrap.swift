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

extension ClusterHelper {

    /// Configures a node. With `sharedImageStore`, it also installs cluster-shim
    /// so the node can use images from the host image store.
    public static func prepareNode(nodeID: String, sharedImageStore: Bool, client: ContainerClient, log: Logger) async throws {
        log.info("Preparing node", metadata: ["id": "\(nodeID)", "sharedImageStore": "\(sharedImageStore)"])
        var script = nodePrepScript
        if sharedImageStore {
            let shim = try await clusterShimURL(log: log)
            try await client.copyIn(id: nodeID, source: shim.path, destination: nodeShimPath, mode: 0o755)
            script = hostImagesScript + "\n" + script
        }

        let result = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", script], client: client)
        guard result.code == 0 else {
            throw ContainerizationError(.internalError, message: "node prep failed on \(nodeID): \(result.output)")
        }
    }

    static func bootstrapControlPlane(
        nodeID: String, nodeImage: String, apiServerSANs: [String], advertiseAddress: String,
        schedulable: Bool, sharedImageStore: Bool, cniManifestPath: String? = nil, client: ContainerClient, log: Logger
    ) async throws {
        let configYAML = try initConfigYAML(
            nodeImage: nodeImage, advertiseAddress: advertiseAddress, certSANs: apiServerSANs, sharedImageStore: sharedImageStore)
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
            let taintCode = try await runProbe(
                client: client, containerId: nodeID,
                arguments: ["taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"])
            guard taintCode == 0 else {
                throw ContainerizationError(.internalError, message: "failed to remove control-plane taint on \(nodeID)")
            }
        }

        if cniManifestPath?.uppercased() == noCNIName {
            log.info("Skipping CNI installation", metadata: ["node": "\(nodeID)"])
        } else {
            log.info("Applying CNI manifest", metadata: ["node": "\(nodeID)"])
            let manifest = try await loadCNIManifest(path: cniManifestPath, log: log)
            let apply = "\(kubeconfigEnv) kubectl apply -f - <<'EOF'\n\(manifest)\nEOF"
            r = try await execCapture(
                containerId: nodeID, executable: "/bin/sh",
                arguments: ["-c", apply], client: client)
            guard r.code == 0 else {
                throw ContainerizationError(.internalError, message: "apply CNI failed on \(nodeID): \(r.output)")
            }
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
        let url = try await pluginResourceURL(log: log).appendingPathComponent("kindnet.yaml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "kindnet manifest resource missing at \(url.path)")
        }
        return contents
    }

    /// Returns the cluster-shim binary in the cluster plugin's resources.
    /// Builds made without container services running do not include it.
    static func clusterShimURL(log: Logger) async throws -> URL {
        let shim = try await pluginResourceURL(log: log).appendingPathComponent("cluster-shim")
        guard FileManager.default.fileExists(atPath: shim.path) else {
            throw ContainerizationError(
                .notFound,
                message: "--shared-image-store needs cluster-shim, and this build of container has none at \(shim.path)")
        }
        return shim
    }

    /// Returns the resources directory of the installed cluster plugin.
    private static func pluginResourceURL(log: Logger) async throws -> URL {
        let pluginLoader = try await Utility.createPluginLoader(log: log)
        guard let plugin = pluginLoader.findPlugin(forExecutable: CommandLine.executablePath),
            let resourceURL = plugin.resourceURL
        else {
            throw ContainerizationError(.internalError, message: "unable to locate cluster plugin installation or resources")
        }
        return resourceURL
    }

    /// Makes cluster-shim containerd's content store: writes hoststore.toml,
    /// imports it from the node image's version 2 config.toml, and starts the
    /// shim before containerd. Runs before `nodePrepScript`, which restarts
    /// containerd. The kubelet uses cluster-shim as its image service, set in
    /// `initConfigYAML`.
    private static var hostImagesScript: String {
        """
        set -e
        mkdir -p /etc/containerd/conf.d
        cat > /etc/containerd/conf.d/hoststore.toml <<'EOF'
        version = 2
        disabled_plugins = ["io.containerd.content.v1.content"]
        [proxy_plugins.hoststore]
          type = "content"
          address = "/run/cluster-shim/content.sock"
        [plugins.'io.containerd.metadata.v1.bolt']
          content_sharing_policy = "shared"
        EOF
        grep -q '^imports' /etc/containerd/config.toml || \\
          sed -i '1i imports = ["/etc/containerd/conf.d/hoststore.toml"]' /etc/containerd/config.toml
        cat > /etc/systemd/system/cluster-shim.service <<'EOF'
        [Unit]
        Description=container cluster host store shim
        Before=containerd.service

        [Service]
        ExecStart=\(nodeShimPath)
        Restart=always

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable --now cluster-shim
        """
    }

    /// Configures containerd, networking and the pause image for the cluster.
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
        /usr/sbin/iptables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        /usr/sbin/iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        """
    }

    static func initConfigYAML(
        nodeImage: String, advertiseAddress: String, certSANs: [String], sharedImageStore: Bool
    ) throws -> String {
        let sans = certSANs.map { "  - \($0)" }.joined(separator: "\n")
        var kubelet = """
            apiVersion: kubelet.config.k8s.io/v1beta1
            kind: KubeletConfiguration
            cgroupDriver: systemd
            failSwapOn: false
            """
        if sharedImageStore {
            kubelet += "\nimageServiceEndpoint: unix://\(nodeImageServiceSocketPath)"
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
            kubernetesVersion: \(try kubernetesVersion(nodeImage: nodeImage))
            networking:
              podSubnet: \(podSubnet)
            apiServer:
              certSANs:
            \(sans)
            ---
            \(kubelet)
            """
    }

    /// kubeadm needs the exact version, and only the tag carries it.
    static func kubernetesVersion(nodeImage: String) throws -> String {
        let nameAndTag = nodeImage.split(separator: "@").first.map(String.init) ?? nodeImage
        guard let ref = try? Reference.parse(nameAndTag), let tag = ref.tag else {
            throw ContainerizationError(
                .invalidArgument,
                message: "node image \(nodeImage) has no tag; use a tagged image such as docker.io/kindest/node:v1.34.11")
        }
        return tag
    }
}
