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
import ContainerVersion
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation
import Logging
import SystemPackage
import Yams

// MARK: - ListDisplayable

protocol ListDisplayable {
    static var tableHeader: [String] { get }
    var tableRow: [String] { get }
    var quietValue: String { get }
}

// MARK: - TableOutput

struct TableOutput: Sendable {
    private let rows: [[String]]
    private let spacing: Int

    init(rows: [[String]], spacing: Int = 2) {
        self.rows = rows
        self.spacing = spacing
    }

    func format() -> String {
        var output = ""
        let maxLengths = self.maxLength()

        for rowIndex in 0..<self.rows.count {
            let row = self.rows[rowIndex]
            for columnIndex in 0..<row.count - 1 {
                let currentLength = (maxLengths[columnIndex] ?? 0) + self.spacing
                let padded = row[columnIndex].padding(toLength: currentLength, withPad: " ", startingAt: 0)
                output += padded
            }
            output += row.last ?? ""
            output += (rowIndex == self.rows.count - 1) ? "" : "\n"
        }
        return output
    }

    private func maxLength() -> [Int: Int] {
        var output: [Int: Int] = [:]
        for row in self.rows {
            for (i, column) in row.enumerated() {
                let currentMax = output[i] ?? 0
                output[i] = (column.count > currentMax) ? column.count : currentMax
            }
        }
        return output
    }
}

// MARK: - K8sHelper

struct K8sHelper {
    static let pluginName: String = "k8s"
    static let defaultName: String = "k8s-dev"
    static let controlPlaneRoleName: String = "control-plane"
    private static var defaultCPUs: Int64 {
        Int64(max(ProcessInfo.processInfo.processorCount / 4, 2))
    }

    private static var defaultMemory: String {
        let gb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) / 4
        return "\(max(gb, 2))g"
    }

    static let nodeImage = "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"
    private static let kubeconfigPath = "/etc/kubernetes/admin.conf"
    private static let kubeconfigEnv = "KUBECONFIG=\(kubeconfigPath)"
    private static let kubectlPath = "/bin/kubectl"
    private static let kubeadmPath = "/usr/bin/kubeadm"
    private static let ignorePreflightErrors =
        "Swap,SystemVerification,FileContent--proc-sys-net-bridge-bridge-nf-call-iptables"
    private static let podSubnet = "10.244.0.0/16"
    // kubeadm default service subnet; must stay in sync if ClusterConfiguration.serviceSubnet is ever set.
    private static let serviceSubnet = "10.96.0.0/12"

    // Proxy env var names forwarded from the host into the cluster container.
    static let proxyEnvVars = ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"]

    // Returns proxy env vars with NO_PROXY augmented to bypass internal cluster CIDRs.
    // Without this, kubelet routes apiserver traffic through the host proxy and times out.
    static func nodeProxyEnv() -> [String] {
        let bypassCIDRs = "192.168.0.0/16,\(podSubnet),\(serviceSubnet)"
        let hostEnv = ProcessInfo.processInfo.environment
        return proxyEnvVars.map { name in
            guard name.uppercased() == "NO_PROXY" else { return name }
            let existing = hostEnv[name] ?? hostEnv[name == "NO_PROXY" ? "no_proxy" : "NO_PROXY"] ?? ""
            let augmented = existing.isEmpty ? bypassCIDRs : "\(existing),\(bypassCIDRs)"
            return "\(name)=\(augmented)"
        }
    }

    private static let clusterContainerPort: UInt16 = 6443
    private static let clusterHostPortBase: UInt16 = 6445

    private static func findAvailableHostPort(excluding: Set<UInt16> = []) throws -> UInt16 {
        var port = clusterHostPortBase
        while port < UInt16.max {
            if excluding.contains(port) {
                port += 1
                continue
            }
            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                throw ContainerizationError(.internalError, message: "socket() failed while probing for available port")
            }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let available = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            Darwin.close(sock)
            if available { return port }
            port += 1
        }
        throw ContainerizationError(.internalError, message: "no available host port found above \(clusterHostPortBase)")
    }

    static func clusterPort() async throws -> String {
        let snapshots = try await ContainerClient().list(
            filters: ContainerListFilters(labels: [ResourceLabelKeys.plugin: pluginName])
        )
        let reserved = Set(snapshots.flatMap { $0.configuration.publishedPorts.map(\.hostPort) })
        let port = try findAvailableHostPort(excluding: reserved)
        return "\(port):\(clusterContainerPort)"
    }

    private static let kubeconfigDir: FilePath = FilePath(
        FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    ).appending(".kube")

    // MARK: - Resource defaults

    static func defaultedResourceFlags(_ flags: Flags.Resource) -> Flags.Resource {
        var f = flags
        if f.cpus == nil { f.cpus = defaultCPUs }
        if f.memory == nil { f.memory = defaultMemory }
        return f
    }

    // MARK: - Image management

    static func ensureImage(nodeImage: String = K8sHelper.nodeImage, log: Logger, containerSystemConfig: ContainerSystemConfig) async throws {
        do {
            _ = try await ClientImage.get(reference: nodeImage, containerSystemConfig: containerSystemConfig)
            log.debug("k8s node image present", metadata: ["ref": "\(nodeImage)"])
            return
        } catch let error as ContainerizationError where error.code == .notFound {
            log.info("Pulling k8s node image", metadata: ["ref": "\(nodeImage)"])
        }
        let platform = try Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
        _ = try await ClientImage.fetch(
            reference: nodeImage,
            platform: platform,
            scheme: .auto,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: nil)
    }

    // MARK: - Node bootstrap

    private static func execCapture(
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

    static func prepareNode(nodeID: String, client: ContainerClient, log: Logger) async throws {
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
        client: ContainerClient, log: Logger
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

        log.info("Removing control-plane taint for single-node scheduling", metadata: ["node": "\(nodeID)"])
        _ = try await runProbe(
            client: client, containerId: nodeID,
            arguments: ["taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"])

        log.info("Applying kindnet CNI", metadata: ["node": "\(nodeID)"])
        let manifest = try loadKindnetManifest()
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

    private static func loadKindnetManifest() throws -> String {
        guard let url = Bundle.module.url(forResource: "kindnet", withExtension: "yaml"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw ContainerizationError(.internalError, message: "kindnet manifest resource missing")
        }
        return contents
    }

    private static let nodePrepScript: String = {
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
    }()

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

    // MARK: - FQDN detection

    static func fqdn(for name: String, domain: String?) -> String? {
        if name.contains(".") { return name }
        guard let domain, !domain.isEmpty else { return nil }
        return "\(name).\(domain)"
    }

    static func detectFQDN(name: String) async -> String? {
        let domain = try? await ConfigurationLoader.load().dns.domain
        return fqdn(for: name, domain: domain)
    }

    // MARK: - Readiness

    static func waitForNodeBooted(containerId: String, client: ContainerClient, log: Logger) async throws {
        let timeout = 120
        log.info("Waiting for node to boot", metadata: ["node": "\(containerId)"])
        for attempt in 1...timeout {
            let result = try await execCapture(
                containerId: containerId, executable: "/bin/sh",
                arguments: ["-c", "test -S /run/containerd/containerd.sock"], client: client)
            if result.code == 0 { return }
            if attempt == timeout {
                log.info("check container logs with 'container logs \(containerId)'")
                throw ContainerizationError(
                    .timeout,
                    message: "node \(containerId) did not boot within \(timeout * 2)s: containerd socket not present at /run/containerd/containerd.sock"
                )
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private static func runProbe(client: ContainerClient, containerId: String, arguments: [String]) async throws -> Int32 {
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        defer { try? devNull?.close() }
        let probe = ProcessConfiguration(
            executable: kubectlPath,
            arguments: arguments,
            environment: [kubeconfigEnv],
            terminal: false)
        let proc = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: probe,
            stdio: [nil, devNull, devNull])
        try await proc.start()
        return try await proc.wait()
    }

    static func waitForReady(containerId: String, client: ContainerClient, log: Logger) async throws {
        let nodeReadyTimeout = 180
        let podReadyTimeout = 300

        log.info("Waiting for control-plane node to become ready")
        for attempt in 1...nodeReadyTimeout {
            let code: Int32
            do {
                code = try await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["wait", "--for=condition=Ready", "node", "--all", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError, message: "k8s cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { break }
            if attempt == nodeReadyTimeout {
                log.info("inspect node state with 'container exec \(containerId) kubectl get nodes -o wide'")
                throw ContainerizationError(
                    .timeout,
                    message: "k8s cluster \(containerId) control-plane node did not become Ready within \(nodeReadyTimeout * 2)s"
                )
            }
            try await Task.sleep(for: .seconds(2))
        }

        log.info("Waiting for kube-system pods to become ready")
        for attempt in 1...podReadyTimeout {
            let code: Int32
            do {
                code = try await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["wait", "--for=condition=Available", "deployment/coredns", "-n", "kube-system", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError, message: "k8s cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { return }
            if attempt < podReadyTimeout {
                try await Task.sleep(for: .seconds(2))
            }
        }
        log.info("inspect pod state with 'container exec \(containerId) kubectl get pods -n kube-system'")
        throw ContainerizationError(
            .timeout,
            message: "k8s cluster \(containerId) kube-system pods did not become available within \(podReadyTimeout * 2)s"
        )
    }

    // MARK: - Kubeconfig

    static func fetchConfig(containerId: String, client: ContainerClient, log: Logger) async throws -> KubeConfig {
        log.info("Fetching kubeconfig", metadata: ["cluster": "\(containerId)"])

        let container = try await client.get(id: containerId)
        guard container.configuration.labels[ResourceLabelKeys.plugin] == pluginName else {
            log.error("container is not a k8s cluster, refusing config fetch", metadata: ["name": "\(containerId)"])
            throw ContainerizationError(.invalidArgument, message: "\(containerId) is not a k8s cluster")
        }

        let (exitCode, yaml) = try await execCapture(
            containerId: containerId, executable: "/bin/cat",
            arguments: [kubeconfigPath], client: client)
        guard exitCode == 0 else {
            throw ContainerizationError(.internalError, message: "failed to read kubeconfig from \(containerId): exit \(exitCode)")
        }
        do {
            return try YAMLDecoder().decode(KubeConfig.self, from: yaml)
        } catch {
            throw ContainerizationError(.internalError, message: "failed to decode kubeconfig from \(containerId): \(error)")
        }
    }

    static func transformConfig(_ config: KubeConfig, containerId: String, fqdn: String?, client: ContainerClient) async throws -> KubeConfig {
        var config = config
        let serverAddress: String
        if let fqdn {
            serverAddress = "https://\(fqdn):6443"
        } else {
            let snapshot = try await client.get(id: containerId)
            guard
                let hostPort = snapshot.configuration.publishedPorts
                    .first(where: { $0.containerPort == clusterContainerPort })?.hostPort
            else {
                throw ContainerizationError(.internalError, message: "no published port for cluster \(containerId)")
            }
            serverAddress = "https://127.0.0.1:\(hostPort)"
        }
        for i in config.clusters.indices {
            config.clusters[i].cluster.server = serverAddress
        }
        // Rename all entries to containerId. kubeadm uses fixed names ("kubernetes",
        // "kubernetes-admin@kubernetes", etc.) rather than "default", so we rename
        // unconditionally and fix up the cross-references in the context.
        config.clusters = config.clusters.map {
            var c = $0
            c.name = containerId
            return c
        }
        config.users = config.users.map {
            var u = $0
            u.name = containerId
            return u
        }
        config.contexts = config.contexts.map {
            var nc = $0
            nc.name = containerId
            nc.context.cluster = containerId
            nc.context.user = containerId
            return nc
        }
        config.currentContext = containerId
        return config
    }

    static func resolveKubeconfigMergePath() -> FilePath {
        let defaultPath = kubeconfigDir.appending("config")
        guard let raw = Darwin.getenv("KUBECONFIG") else { return defaultPath }
        let env = String(cString: raw)
        guard !env.isEmpty else { return defaultPath }
        let paths = env.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return defaultPath }
        if paths.count == 1 { return FilePath(paths[0]) }
        for p in paths where FileManager.default.fileExists(atPath: p) {
            return FilePath(p)
        }
        return FilePath(paths[paths.count - 1])
    }

    static func mergeConfig(_ config: KubeConfig, containerId: String, targetPath: FilePath? = nil, setCurrentContext: Bool = false, log: Logger) throws {
        let path = targetPath ?? resolveKubeconfigMergePath()
        log.info("Writing kubeconfig", metadata: ["cluster": "\(containerId)", "path": "\(path)"])

        let targetDir = path.removingLastComponent()
        try FileManager.default.createDirectory(atPath: targetDir.string, withIntermediateDirectories: true)

        var existing: KubeConfig
        if FileManager.default.fileExists(atPath: path.string) {
            do {
                let yaml = try String(contentsOfFile: path.string, encoding: .utf8)
                existing = try YAMLDecoder().decode(KubeConfig.self, from: yaml)
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "kubeconfig at \(path) could not be parsed: \(error)"
                )
            }
        } else {
            existing = .empty
        }

        existing.clusters.removeAll { $0.name == containerId }
        existing.contexts.removeAll { $0.name == containerId }
        existing.users.removeAll { $0.name == containerId }

        existing.clusters.append(contentsOf: config.clusters)
        existing.contexts.append(contentsOf: config.contexts)
        existing.users.append(contentsOf: config.users)
        if setCurrentContext {
            existing.currentContext = containerId
        }

        let output = try YAMLEncoder().encode(existing)
        try output.write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    static func removeConfig(containerId: String, log: Logger) throws {
        let path = resolveKubeconfigMergePath()
        log.info("Removing kubeconfig", metadata: ["cluster": "\(containerId)", "path": "\(path)"])

        guard FileManager.default.fileExists(atPath: path.string) else { return }

        let existing: KubeConfig
        do {
            let yaml = try String(contentsOfFile: path.string, encoding: .utf8)
            existing = try YAMLDecoder().decode(KubeConfig.self, from: yaml)
        } catch {
            log.warning("kubeconfig exists but could not be parsed, skipping removal", metadata: ["path": "\(path)", "error": "\(error)"])
            return
        }

        var updated = existing

        updated.clusters.removeAll { $0.name == containerId }
        updated.contexts.removeAll { $0.name == containerId }
        updated.users.removeAll { $0.name == containerId }

        if updated.currentContext == containerId {
            updated.currentContext = nil
        }

        let output = try YAMLEncoder().encode(updated)
        try output.write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    // MARK: - List rows

    static func buildK8sRows(from snapshots: [ContainerSnapshot]) -> [K8sNodeResource] {
        var controlPlanes: [ContainerSnapshot] = []
        var workers: [ContainerSnapshot] = []
        for snapshot in snapshots {
            switch snapshot.configuration.labels[ResourceLabelKeys.role] {
            case controlPlaneRoleName: controlPlanes.append(snapshot)
            default: workers.append(snapshot)
            }
        }

        var rows: [K8sNodeResource] = []
        var assignedWorkerIDs = Set<String>()

        for cp in controlPlanes.sorted(by: { $0.configuration.id < $1.configuration.id }) {
            let clusterName = cp.configuration.id
            rows.append(K8sNodeResource(clusterName: clusterName, snapshot: cp))
            let cpWorkers =
                workers
                .filter { $0.configuration.id.hasPrefix("\(clusterName)-worker-") }
                .sorted { $0.configuration.id < $1.configuration.id }
            for w in cpWorkers {
                rows.append(K8sNodeResource(clusterName: clusterName, snapshot: w))
                assignedWorkerIDs.insert(w.configuration.id)
            }
        }

        for w
            in workers
            .filter({ !assignedWorkerIDs.contains($0.configuration.id) })
            .sorted(by: { $0.configuration.id < $1.configuration.id })
        {
            let clusterName = w.configuration.id
                .components(separatedBy: "-worker-").dropLast().joined(separator: "-worker-")
            rows.append(K8sNodeResource(clusterName: clusterName, snapshot: w))
        }

        return rows
    }

    static func renderTable<T: ListDisplayable>(_ items: [T]) -> String {
        var rows: [[String]] = [T.tableHeader]
        for item in items {
            rows.append(item.tableRow)
        }
        return TableOutput(rows: rows).format()
    }

    // MARK: - Image reference helpers

    static func isShortName(_ reference: String) -> Bool {
        guard let ref = try? Reference.parse(reference) else { return true }
        return ref.domain == nil
    }

    static func fqReference(_ reference: String) -> String {
        guard let ref = try? Reference.parse(reference) else { return reference }
        ref.normalize()
        return ref.description
    }
}

// MARK: - K8sNodeResource

struct K8sNodeResource: ManagedResource, ListDisplayable {
    let clusterName: String
    let snapshot: ContainerSnapshot

    // MARK: ManagedResource
    var id: String { snapshot.configuration.id }
    var name: String { snapshot.configuration.id }
    var creationDate: Date { snapshot.configuration.creationDate }
    var labels: ResourceLabels { (try? ResourceLabels(snapshot.configuration.labels)) ?? .init() }

    static func nameValid(_ name: String) -> Bool { ManagedContainer.nameValid(name) }

    static var tableHeader: [String] {
        ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"]
    }

    var tableRow: [String] {
        let role = snapshot.configuration.labels[ResourceLabelKeys.role] ?? ""
        let addr = snapshot.networks.map { $0.ipv4Address.address.description }.joined(separator: ",")
        let memoryMB = snapshot.configuration.resources.memoryInBytes / (1024 * 1024)
        let ports = snapshot.configuration.publishedPorts
            .map { "\($0.hostPort)->\($0.containerPort)" }
            .joined(separator: ",")
        return [
            clusterName,
            snapshot.configuration.id,
            role,
            snapshot.status.rawValue,
            "\(snapshot.configuration.resources.cpus)",
            "\(memoryMB) MB",
            addr,
            ports,
        ]
    }

    var quietValue: String { snapshot.configuration.id }
}
