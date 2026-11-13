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
import ContainerClusterServiceClient
import ContainerPlugin
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

// MARK: - ClusterHelper

public struct ClusterHelper {
    public static let pluginName: String = ResourcePluginValues.cluster
    public static let defaultName: String = "cluster-dev"
    public static let controlPlaneRoleName: String = ClusterConfiguration.controlPlaneRole
    public static let workerRoleName: String = ClusterConfiguration.workerRole
    private static var defaultCPUs: Int64 {
        Int64(max(ProcessInfo.processInfo.processorCount / 4, 2))
    }
    private static var defaultMemory: String {
        let gb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) / 4
        return "\(max(gb, 2))g"
    }

    /// A Kubernetes minor version that `container cluster` supports, and the node image it uses.
    public struct SupportedVersion: Sendable, Equatable {
        /// The Kubernetes minor version, e.g. `1.37`.
        public let kubernetesVersion: String
        /// The kind node image for that version, pinned by digest.
        public let nodeImage: String
    }

    /// The Kubernetes versions `container cluster` supports, newest first; the first is the default.
    /// Images come from one kind release and are pinned by digest. Each entry needs the bootstrapper
    /// to handle that version, so add one only after testing it.
    public static let supportedVersions: [SupportedVersion] = [
        SupportedVersion(
            kubernetesVersion: "1.37",
            nodeImage: "docker.io/kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"),
        SupportedVersion(
            kubernetesVersion: "1.36",
            nodeImage: "docker.io/kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed"),
        SupportedVersion(
            kubernetesVersion: "1.35",
            nodeImage: "docker.io/kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"),
    ]

    public static let nodeImage = supportedVersions[0].nodeImage

    /// The supported version matching `version` (`1.36` or `v1.36`), or nil.
    public static func supportedVersion(_ version: String) -> SupportedVersion? {
        let minor = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return supportedVersions.first { $0.kubernetesVersion == minor }
    }

    /// The supported versions as a list for messages, e.g. `1.37, 1.36, 1.35`.
    public static var supportedVersionList: String {
        supportedVersions.map(\.kubernetesVersion).joined(separator: ", ")
    }

    /// Whether a node image carries a supported Kubernetes minor version.
    static func isSupported(nodeImage: String) -> Bool {
        guard let tag = try? ClusterConfiguration.kubernetesVersion(nodeImage: nodeImage) else { return false }
        return supportedVersions.contains { tag.hasPrefix("v\($0.kubernetesVersion).") }
    }
    static let kubeconfigPath = "/etc/kubernetes/admin.conf"
    static let kubeconfigEnv = "KUBECONFIG=/etc/kubernetes/admin.conf"
    static let kubectlPath = "/bin/kubectl"
    public static let kubeadmPath = "/usr/bin/kubeadm"
    public static let ignorePreflightErrors =
        "Swap,SystemVerification,FileContent--proc-sys-net-bridge-bridge-nf-call-iptables"
    static let podSubnet = "10.244.0.0/16"
    /// Sentinel value for `--cni` (compared case-insensitively) that skips installing a CNI entirely.
    static let noCNIName = "NONE"
    // kubeadm default service subnet; must stay in sync if ClusterConfiguration.serviceSubnet is ever set.
    static let serviceSubnet = "10.96.0.0/12"

    // Proxy env var names forwarded from the host into the cluster container.
    static let proxyEnvVars = ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"]

    public static let clusterContainerPort: UInt16 = 6443

    /// Host socket served by the cluster-hoststore plugin and relayed into each node.
    public static let hostStoreSocketPath = ApplicationRoot.path.appending("cluster-hoststore.sock")
    /// Where the host store socket appears inside a node. Must match cluster-shim.
    static let nodeHostStoreSocketPath = "/opt/cluster-shim/hoststore.sock"
    /// Where the cluster-shim binary is installed inside a node.
    static let nodeShimPath = "/usr/local/bin/cluster-shim"
    /// The kubelet's CRI image service, served by cluster-shim. Must match cluster-shim.
    static let nodeImageServiceSocketPath = "/run/cluster-shim/cri-image.sock"

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
    static func pluginResourceURL(log: Logger) async throws -> URL {
        let pluginLoader = try await Utility.createPluginLoader(log: log)
        guard let plugin = pluginLoader.findPlugin(forExecutable: CommandLine.executablePath),
            let resourceURL = plugin.resourceURL
        else {
            throw ContainerizationError(.internalError, message: "unable to locate cluster plugin installation or resources")
        }
        return resourceURL
    }

    public static var nodeEntrypointScript: String {
        """
        set -e
        log_info()  { echo "INFO: $1" >&2; }
        log_error() { echo "ERROR: $1" >&2; }

        # Disable the createContainer hook that copies /kind/product_* into every
        # container's rootfs. Testing whether container cluster needs this at all --
        # unconfirmed whether container's VMs already assign a unique product_uuid
        # per node without it.
        if [ -f /etc/containerd/cri-base.json ]; then
        if jq 'del(.hooks.createContainer)' /etc/containerd/cri-base.json > /tmp/cri-base.json.new; then
            mv /tmp/cri-base.json.new /etc/containerd/cri-base.json
            log_info "removed createContainer hook from cri-base.json"
        else
            log_error "jq failed to patch cri-base.json, leaving it unmodified"
        fi
        fi

        # Proxy propagation.
        mkdir -p /etc/systemd/system.conf.d/
        cat <<EOF >/etc/systemd/system.conf.d/proxy-default-environment.conf
        [Manager]
        DefaultEnvironment="HTTP_PROXY=${HTTP_PROXY:-}" "HTTPS_PROXY=${HTTPS_PROXY:-}" "NO_PROXY=${NO_PROXY:-}"
        EOF

        # Mount propagation. Unverified whether this is needed in container's VM boot.
        mount --make-rshared /

        # Detect the node's current IPv4 address, preferring the default-route interface.
        DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
        if [ -n "$DEFAULT_IFACE" ]; then
        CURRENT_IP=$(ip -4 -o addr show dev "$DEFAULT_IFACE" | awk '{print $4}' | head -1 | cut -d/ -f1)
        else
        CURRENT_IP=$(ip -4 -o addr show | awk '$2 != "lo" && $2 !~ /^veth/ {print $4}' | head -1 | cut -d/ -f1)
        fi
        # Read the IP recorded on the previous boot, if any.
        IP_MARKER=/etc/.container-cluster-last-ip
        OLD_IP=""
        [ -f "$IP_MARKER" ] && OLD_IP=$(cat "$IP_MARKER")

        # If the node IP changed across a restart, rewrite the old IP in the cluster
        # config files and regenerate the apiserver certificate for the new IP.
        if [ -n "$OLD_IP" ] && [ -n "$CURRENT_IP" ] && [ "$OLD_IP" != "$CURRENT_IP" ] && [ -f /etc/kubernetes/pki/apiserver.crt ]; then
        log_info "node IP changed ($OLD_IP -> $CURRENT_IP), reconciling cluster config"
        # Escape dots so OLD_IP matches literally, and anchor on word boundaries so it
        # cannot match inside a longer address.
        OLD_RE=$(printf '%s' "$OLD_IP" | sed 's/\\./\\\\./g')
        for f in /etc/kubernetes/kubeadm-config.yaml \\
                /etc/kubernetes/manifests/etcd.yaml \\
                /etc/kubernetes/manifests/kube-apiserver.yaml \\
                /etc/kubernetes/manifests/kube-controller-manager.yaml \\
                /etc/kubernetes/manifests/kube-scheduler.yaml \\
                /etc/kubernetes/controller-manager.conf \\
                /etc/kubernetes/scheduler.conf \\
                /etc/kubernetes/kubelet.conf \\
                /etc/kubernetes/admin.conf \\
                /root/.kube/config \\
                /var/lib/kubelet/kubeadm-flags.env; do
            [ -f "$f" ] && sed -i "s#\\b${OLD_RE}\\b#${CURRENT_IP}#g" "$f"
        done
        # Regenerate the apiserver certificate so its SANs include the new IP.
        rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
        if ! kubeadm init phase certs apiserver --config /etc/kubernetes/kubeadm-config.yaml; then
            log_error "apiserver cert regeneration failed after IP change"
            exit 1
        fi
        log_info "reconciliation complete"
        fi

        # Record the current IP for the next boot, then hand off to the original command.
        [ -n "$CURRENT_IP" ] && echo "$CURRENT_IP" > "$IP_MARKER"
        exec  "$@"
        """
    }

    // MARK: - Resource defaults

    public static func defaultedResourceFlags(_ flags: Flags.Resource) -> Flags.Resource {
        var f = flags
        if f.cpus == nil { f.cpus = defaultCPUs }
        if f.memory == nil { f.memory = defaultMemory }
        return f
    }

    // Shared exec helper used by bootstrap, readiness, and kubeconfig extensions.
    public static func execCapture(
        containerId: String, executable: String, arguments: [String],
        client: ContainerClient
    ) async throws -> (code: Int32, output: String) {
        let pipe = Pipe()
        let config = ProcessConfiguration(
            executable: executable, arguments: arguments, environment: [], terminal: false)
        let proc = try await client.createProcess(
            containerId: containerId, processId: UUID().uuidString.lowercased(),
            configuration: config, stdio: [nil, pipe.fileHandleForWriting, pipe.fileHandleForWriting])
        try await proc.start()
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        let code = try await proc.wait()
        return (code, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Node enumeration

    /// Container name of the `index`th (1-based) worker of `cluster`. `list` and `delete` find workers by this prefix.
    static func workerName(cluster: String, index: Int) -> String {
        ClusterConfiguration.workerName(cluster: cluster, index: index)
    }

    static func workerNamePrefix(cluster: String) -> String {
        ClusterConfiguration.workerNamePrefix(cluster: cluster)
    }

    /// Names of worker containers belonging to `clusterName`, sorted (e.g. `<clusterName>-worker-1`).
    /// Only dedicated workers are returned, never the control-plane container. With no workers
    /// (`--workers 0`) the control plane doubles as the worker node and this list is empty; with
    /// one or more workers the control plane is tainted and is not a combined control-plane/worker node.
    static func workerContainerNames(clusterName: String, client: ContainerClient) async throws -> [String] {
        let snapshots = try await client.list(
            filters: ContainerListFilters().withPlugin(pluginName)
        )
        return workerContainerNames(from: snapshots, clusterName: clusterName)
    }

    /// Pure filtering logic behind `workerContainerNames(clusterName:client:)`, split out for unit testing.
    static func workerContainerNames(from snapshots: [ContainerSnapshot], clusterName: String) -> [String] {
        snapshots
            .filter { $0.configuration.labels[ResourceLabelKeys.role] == workerRoleName }
            .map { $0.configuration.id }
            .filter { $0.hasPrefix(workerNamePrefix(cluster: clusterName)) }
            .sorted()
    }

    // MARK: - List output

    /// Builds one row per node of every cluster. CPU and memory come from the node's container, when one exists.
    static func buildNodeRows(infos: [ClusterResource], snapshots: [ContainerSnapshot]) -> [ClusterNodeRow] {
        var rows: [ClusterNodeRow] = []

        for cluster in infos {
            for node in cluster.configuration.nodes {
                let state =
                    cluster.status.nodes.first { $0.name == node.name }
                    ?? ClusterNodeState(name: node.name, status: .stopped)
                let container = snapshots.first { $0.configuration.id == node.name }

                var cpus = ""
                var memory = ""
                if let resources = container?.configuration.resources {
                    cpus = "\(resources.cpus)"
                    memory = formatMemory(bytes: resources.memoryInBytes)
                }

                rows.append(
                    ClusterNodeRow(
                        clusterName: cluster.configuration.name, node: node, state: state,
                        cpus: cpus, memory: memory))
            }
        }

        return rows
    }

    private static func formatMemory(bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func renderTable<T: ListDisplayable>(_ items: [T]) -> String {
        var rows: [[String]] = [T.tableHeader]
        for item in items {
            rows.append(item.tableRow)
        }
        return TableOutput(rows: rows).format()
    }
}

extension ClusterResource: ListDisplayable {
    static var tableHeader: [String] { ["NAME", "NODES", "K8S VERSION", "STATE"] }

    var stateText: String {
        switch status.state {
        case .running, .stopped:
            return status.state.rawValue
        case .degraded:
            let nodes = status.nodes
            let up = nodes.filter { $0.status == .running }.count
            return "\(status.state.rawValue) (\(up) of \(nodes.count) up)"
        }
    }

    var tableRow: [String] {
        [configuration.name, "\(status.nodes.count)", configuration.kubernetesVersion, stateText]
    }

    var quietValue: String { configuration.name }
}

struct ClusterNodeRow: ListDisplayable {
    let clusterName: String
    let node: NodeConfiguration
    let state: ClusterNodeState
    let cpus: String
    let memory: String

    static var tableHeader: [String] {
        ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"]
    }

    var tableRow: [String] {
        [
            clusterName, node.name, node.roles.joined(separator: ","),
            state.status.rawValue, cpus, memory,
            (state.addresses ?? []).joined(separator: ","),
            (state.ports ?? []).joined(separator: ","),
        ]
    }

    var quietValue: String { node.name }
}
