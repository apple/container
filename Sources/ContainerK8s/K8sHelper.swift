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

// MARK: - K8sHelper

public struct K8sHelper {
    public enum StandardInput: Sendable {
        case data(Data)
        case file(URL)
    }

    struct ExecProcess: Sendable {
        let start: @Sendable () async throws -> Void
        let wait: @Sendable () async throws -> Int32
    }

    typealias ProcessCreator = @Sendable (ProcessConfiguration, [FileHandle?]) async throws -> ExecProcess

    public static let pluginName: String = "k8s"
    public static let defaultName: String = "k8s-dev"
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

    static func buildK8sRows(from snapshots: [ContainerSnapshot]) -> [K8sNodeResource] {
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
}

private struct PreparedInput: Sendable {
    let transferredHandle: FileHandle?
    let writer: InputWriter?

    func closeWriter() {
        writer?.close()
    }
}

private final class InputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let data: Data
    private let lock = NSLock()
    private var closed = false

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
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

private final class OutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

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
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
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
