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
import ContainerizationOS
import Darwin
import Dispatch
import Foundation
import Logging
import Synchronization

// MARK: - ClusterHelper

public struct ClusterHelper {
    public enum StandardInput: Sendable {
        case data(Data)
        case file(URL)
    }

    struct ExecProcess: Sendable {
        let start: @Sendable () async throws -> Void
        let wait: @Sendable () async throws -> Int32
    }

    typealias ProcessCreator = @Sendable (ProcessConfiguration, [FileHandle?]) async throws -> ExecProcess

    public static let pluginName: String = "cluster"
    public static let defaultName: String = "cluster-dev"
    public static let controlPlaneRoleName: String = "control-plane"
    public static let workerRoleName: String = "worker"
    private static var defaultCPUs: Int64 {
        Int64(max(ProcessInfo.processInfo.processorCount / 4, 2))
    }
    private static var defaultMemory: String {
        let gb = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) / 4
        return "\(max(gb, 2))g"
    }

    public static let nodeImage = "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"
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
        environment: [String] = [], standardInput: StandardInput? = nil,
        client: ContainerClient
    ) async throws -> (code: Int32, output: String) {
        try await execCapture(
            executable: executable,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            processCreator: { configuration, stdio in
                let process = try await client.createProcess(
                    containerId: containerId,
                    processId: UUID().uuidString.lowercased(),
                    configuration: configuration,
                    stdio: stdio)
                return ExecProcess(
                    start: { try await process.start() },
                    wait: { try await process.wait() })
            })
    }

    static func execCapture(
        executable: String, arguments: [String], environment: [String] = [],
        standardInput: StandardInput? = nil, processCreator: ProcessCreator
    ) async throws -> (code: Int32, output: String) {
        let outputPipe = Pipe()
        let outputReader = OutputReader(outputPipe.fileHandleForReading)
        let outputDescriptor = outputPipe.fileHandleForWriting.fileDescriptor
        let stdoutDescriptor = dup(outputDescriptor)
        guard stdoutDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stderrDescriptor = dup(outputDescriptor)
        guard stderrDescriptor >= 0 else {
            close(stdoutDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try outputPipe.fileHandleForWriting.close()
        } catch {
            close(stdoutDescriptor)
            close(stderrDescriptor)
            throw error
        }

        let preparedInput: PreparedInput
        do {
            preparedInput = try prepareStandardInput(standardInput)
        } catch {
            close(stdoutDescriptor)
            close(stderrDescriptor)
            outputReader.close()
            throw error
        }

        let stdoutHandle = FileHandle(fileDescriptor: stdoutDescriptor, closeOnDealloc: false)
        let stderrHandle = FileHandle(fileDescriptor: stderrDescriptor, closeOnDealloc: false)
        let config = ProcessConfiguration(
            executable: executable, arguments: arguments, environment: environment, terminal: false)
        let process: ExecProcess
        do {
            process = try await processCreator(
                config, [preparedInput.transferredHandle, stdoutHandle, stderrHandle])
        } catch {
            preparedInput.closeWriter()
            outputReader.close()
            throw error
        }

        let inputTask = preparedInput.writer.map { writer in
            Task { try await writer.write() }
        }
        let outputTask = Task { try await outputReader.read() }

        do {
            try await process.start()
            let code = try await process.wait()
            try await inputTask?.value
            let data = try await outputTask.value
            return (code, String(data: data, encoding: .utf8) ?? "")
        } catch {
            inputTask?.cancel()
            outputTask.cancel()
            preparedInput.closeWriter()
            outputReader.close()
            throw error
        }
    }

    private static func prepareStandardInput(_ input: StandardInput?) throws -> PreparedInput {
        guard let input else {
            return PreparedInput(transferredHandle: nil, writer: nil)
        }

        switch input {
        case .data(let data):
            let pipe = Pipe()
            let inputDescriptor = dup(pipe.fileHandleForReading.fileDescriptor)
            guard inputDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                try pipe.fileHandleForReading.close()
            } catch {
                close(inputDescriptor)
                throw error
            }
            return PreparedInput(
                transferredHandle: FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: false),
                writer: InputWriter(handle: pipe.fileHandleForWriting, data: data))
        case .file(let url):
            let inputDescriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            guard inputDescriptor >= 0 else {
                let cause = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                throw ContainerizationError(
                    .invalidArgument,
                    message: "failed to open standard input at \(url.path)",
                    cause: cause)
            }
            var status = stat()
            guard fstat(inputDescriptor, &status) == 0 else {
                let cause = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(inputDescriptor)
                throw ContainerizationError(
                    .invalidArgument,
                    message: "failed to inspect standard input at \(url.path)",
                    cause: cause)
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                close(inputDescriptor)
                throw ContainerizationError(
                    .invalidArgument,
                    message: "standard input at \(url.path) is not a regular file")
            }
            return PreparedInput(
                transferredHandle: FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: false),
                writer: nil)
        }
    }

    // MARK: - Node enumeration

    /// Names of worker containers belonging to `clusterName`, sorted (e.g. `<clusterName>-worker-1`).
    /// Only dedicated workers are returned, never the control-plane container. With no workers
    /// (`--workers 0`) the control plane doubles as the worker node and this list is empty; with
    /// one or more workers the control plane is tainted and is not a combined control-plane/worker node.
    static func workerContainerNames(clusterName: String, client: ContainerClient) async throws -> [String] {
        let snapshots = try await client.list(
            filters: ContainerListFilters(labels: [ResourceLabelKeys.plugin: pluginName])
        )
        return workerContainerNames(from: snapshots, clusterName: clusterName)
    }

    /// Pure filtering logic behind `workerContainerNames(clusterName:client:)`, split out for unit testing.
    static func workerContainerNames(from snapshots: [ContainerSnapshot], clusterName: String) -> [String] {
        snapshots
            .filter { $0.configuration.labels[ResourceLabelKeys.role] == workerRoleName }
            .map { $0.configuration.id }
            .filter { $0.hasPrefix("\(clusterName)-worker-") }
            .sorted()
    }

    // MARK: - List rows

    static func buildClusterRows(from snapshots: [ContainerSnapshot]) -> [ClusterNodeResource] {
        var controlPlanes: [ContainerSnapshot] = []
        var workers: [ContainerSnapshot] = []
        for snapshot in snapshots {
            let roles = snapshot.configuration.labels[ResourceLabelKeys.role, default: ""]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if roles.contains(controlPlaneRoleName) {
                controlPlanes.append(snapshot)
            } else {
                workers.append(snapshot)
            }
        }

        var rows: [ClusterNodeResource] = []
        var assignedWorkerIDs = Set<String>()

        for cp in controlPlanes.sorted(by: { $0.configuration.id < $1.configuration.id }) {
            let clusterName = cp.configuration.id
            rows.append(ClusterNodeResource(clusterName: clusterName, snapshot: cp))
            let cpWorkers =
                workers
                .filter { $0.configuration.id.hasPrefix("\(clusterName)-worker-") }
                .sorted { $0.configuration.id < $1.configuration.id }
            for w in cpWorkers {
                rows.append(ClusterNodeResource(clusterName: clusterName, snapshot: w))
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
            rows.append(ClusterNodeResource(clusterName: clusterName, snapshot: w))
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
}

private struct PreparedInput: Sendable {
    let transferredHandle: FileHandle?
    let writer: InputWriter?

    func closeWriter() {
        writer?.close()
    }
}

private final class InputWriter: Sendable {
    private let handle: FileHandle
    private let data: Data
    private let closed = Mutex(false)

    init(handle: FileHandle, data: Data) {
        self.handle = handle
        self.data = data
    }

    func write() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try self.handle.write(contentsOf: self.data)
                    self.close()
                    continuation.resume(returning: ())
                } catch {
                    self.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        let shouldClose = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        try? handle.close()
    }
}

private final class OutputReader: Sendable {
    private let handle: FileHandle
    private let closed = Mutex(false)

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try self.handle.readToEnd() ?? Data()
                    self.close()
                    continuation.resume(returning: data)
                } catch {
                    self.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        let shouldClose = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        try? handle.close()
    }
}

// MARK: - ClusterNodeResource

struct ClusterNodeResource: ManagedResource, ListDisplayable {
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
