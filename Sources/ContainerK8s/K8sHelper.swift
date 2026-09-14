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
import Foundation
import Logging

// MARK: - K8sHelper

public struct K8sHelper {
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
