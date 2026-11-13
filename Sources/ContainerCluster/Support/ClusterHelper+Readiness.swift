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

extension ClusterHelper {
    // MARK: - Readiness

    public static func runProbe(client: ContainerClient, containerId: String, arguments: [String]) async throws -> Int32 {
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

    public static func waitForNodeBooted(containerId: String, client: ContainerClient, log: Logger) async throws {
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

    /// Wait until the API server is serving. This is the one readiness signal
    /// that does not depend on a CNI being installed.
    static func waitForAPIServer(containerId: String, client: ContainerClient, log: Logger) async throws {
        let timeout = 60
        log.info("Waiting for API server to become available")
        for attempt in 1...timeout {
            let code: Int32
            do {
                code = try await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["get", "--raw", "/readyz", "--request-timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError, message: "cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { return }
            if attempt == timeout {
                log.info("check control-plane logs with 'container logs \(containerId)'")
                throw ContainerizationError(
                    .timeout,
                    message: "cluster \(containerId) API server did not become available within \(timeout * 2)s")
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// True when `renewTime` (a Kubernetes MicroTime) parses and is later than `since`.
    static func leaseRenewedAfter(renewTime: String, since: Date) -> Bool {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: renewTime) {
            return date > since
        }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: renewTime) {
            return date > since
        }
        return false
    }

    /// Waits until the node's Lease has been renewed after `since`, which shows its kubelet is reporting to the API server.
    static func waitForNodeLease(
        nodeName: String, clusterName: String, since: Date, client: ContainerClient, log: Logger
    ) async throws {
        let timeout = 180
        log.info("Waiting for node lease", metadata: ["node": "\(nodeName)"])
        for attempt in 1...timeout {
            let result = try await execCapture(
                containerId: clusterName, executable: "/bin/sh",
                arguments: [
                    "-c",
                    "\(kubeconfigEnv) \(kubectlPath) get lease \(nodeName) -n kube-node-lease -o jsonpath='{.spec.renewTime}' --request-timeout=2s",
                ],
                client: client)
            let renewTime = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.code == 0 && leaseRenewedAfter(renewTime: renewTime, since: since) {
                return
            }
            if attempt == timeout {
                throw ContainerizationError(
                    .timeout,
                    message: "node \(nodeName) did not renew its lease within \(timeout * 2)s of starting")
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// True when `addresses` (whitespace-separated) holds exactly one address and it is `controlPlaneAddress`.
    static func apiEndpointIsCurrent(addresses: String, controlPlaneAddress: String) -> Bool {
        let listed = addresses.split(whereSeparator: { $0.isWhitespace })
        guard listed.count == 1 else {
            return false
        }
        return listed[0] == controlPlaneAddress
    }

    /// Waits until the `kubernetes` Endpoints lists only `controlPlaneAddress` and the CoreDNS pods are Ready.
    static func waitForClusterDNS(
        clusterName: String, controlPlaneAddress: String, client: ContainerClient, log: Logger
    ) async throws {
        let timeout = 60
        log.info("Waiting for the API endpoint and CoreDNS to be ready")
        var unmetCondition = ""
        for attempt in 1...timeout {
            let endpoints = try await execCapture(
                containerId: clusterName, executable: "/bin/sh",
                arguments: [
                    "-c",
                    "\(kubeconfigEnv) \(kubectlPath) get endpoints kubernetes -o jsonpath='{.subsets[*].addresses[*].ip}' --request-timeout=2s",
                ],
                client: client)
            let endpointIsCurrent =
                endpoints.code == 0
                && apiEndpointIsCurrent(addresses: endpoints.output, controlPlaneAddress: controlPlaneAddress)

            let podsCode = try await runProbe(
                client: client, containerId: clusterName,
                arguments: [
                    "-n", "kube-system", "wait", "--for=condition=Ready", "pod", "-l", "k8s-app=kube-dns", "--timeout=2s",
                ])
            let podsAreReady = podsCode == 0

            if endpointIsCurrent && podsAreReady {
                return
            }
            if !endpointIsCurrent {
                unmetCondition = "the kubernetes endpoint did not list only the control-plane address \(controlPlaneAddress)"
            } else {
                unmetCondition = "the CoreDNS pods were not Ready"
            }
            if attempt == timeout {
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        log.info("inspect with 'container exec \(clusterName) kubectl -n kube-system get pods'")
        throw ContainerizationError(
            .timeout,
            message: "cluster \(clusterName) DNS was not ready within \(timeout * 2)s: \(unmetCondition)")
    }

    struct NodePodNetwork: Equatable {
        let name: String
        let podCIDR: String
        let internalIP: String
    }

    /// Parses `<name> <podCIDR> <internalIP>` lines. Lines without exactly three fields are dropped.
    static func parseNodePodNetworks(_ output: String) -> [NodePodNetwork] {
        var nodes: [NodePodNetwork] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 3 else {
                continue
            }
            nodes.append(NodePodNetwork(name: String(fields[0]), podCIDR: String(fields[1]), internalIP: String(fields[2])))
        }
        return nodes
    }

    /// Lists each route a node lacks to another node's pod CIDR via that node's InternalIP.
    /// `routesByNode` maps a node name to the output of `ip -4 route` on that node.
    static func missingPodRoutes(nodes: [NodePodNetwork], routesByNode: [String: String]) -> [String] {
        var missing: [String] = []
        for node in nodes {
            let lines = routesByNode[node.name, default: ""].split(whereSeparator: { $0.isNewline })
            for other in nodes where other.name != node.name {
                let route = "\(other.podCIDR) via \(other.internalIP)"
                if !lines.contains(where: { $0 == route || $0.hasPrefix(route + " ") }) {
                    missing.append("\(node.name) has no route to \(other.podCIDR) via \(other.internalIP)")
                }
            }
        }
        return missing
    }

    /// Returns a count mismatch if `nodes` is not `expectedNodeCount` long, otherwise the missing routes.
    static func podNetworkProblems(
        nodes: [NodePodNetwork], expectedNodeCount: Int, routesByNode: [String: String]
    ) -> [String] {
        if nodes.count != expectedNodeCount {
            return ["found \(nodes.count) of \(expectedNodeCount) nodes with a pod CIDR and InternalIP"]
        }
        return missingPodRoutes(nodes: nodes, routesByNode: routesByNode)
    }

    /// Waits until every node has a route to every other node's pod CIDR via that node's InternalIP.
    static func waitForPodNetworkRoutes(
        clusterName: String, expectedNodeCount: Int, client: ContainerClient, log: Logger
    ) async throws {
        let timeout = 90
        let listNodes =
            #"\#(kubeconfigEnv) \#(kubectlPath) get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.podCIDR}{" "}"#
            + #"{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' --request-timeout=2s"#
        log.info("Waiting for pod network routes")
        var problems: [String] = []
        var loggedNodes = false
        for attempt in 1...timeout {
            let listed = try await execCapture(
                containerId: clusterName, executable: "/bin/sh", arguments: ["-c", listNodes], client: client)
            let nodes = parseNodePodNetworks(listed.output)
            if !nodes.isEmpty && !loggedNodes {
                for node in nodes {
                    log.info(
                        "Checking pod network routes",
                        metadata: ["node": "\(node.name)", "podCIDR": "\(node.podCIDR)", "internalIP": "\(node.internalIP)"])
                }
                loggedNodes = true
            }
            var routesByNode: [String: String] = [:]
            for node in nodes {
                let routes = try await execCapture(
                    containerId: node.name, executable: "/bin/sh", arguments: ["-c", "ip -4 route"], client: client)
                routesByNode[node.name] = routes.output
            }
            problems = podNetworkProblems(nodes: nodes, expectedNodeCount: expectedNodeCount, routesByNode: routesByNode)
            if listed.code == 0 && problems.isEmpty {
                return
            }
            if attempt == timeout {
                break
            }
            try await Task.sleep(for: .seconds(2))
        }
        log.info("inspect with 'container exec <node> ip route'")
        throw ContainerizationError(
            .timeout,
            message: "pod network routes were not restored within \(timeout * 2)s: \(problems.prefix(3).joined(separator: "; "))")
    }

    static func waitForReady(containerId: String, client: ContainerClient, log: Logger) async throws {
        try await waitForAPIServer(containerId: containerId, client: client, log: log)

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
                    .internalError, message: "cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { break }
            if attempt == nodeReadyTimeout {
                log.info("inspect node state with 'container exec \(containerId) kubectl get nodes -o wide'")
                throw ContainerizationError(
                    .timeout,
                    message: "cluster \(containerId) control-plane node did not become Ready within \(nodeReadyTimeout * 2)s"
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
                    .internalError, message: "cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { return }
            if attempt < podReadyTimeout {
                try await Task.sleep(for: .seconds(2))
            }
        }
        log.info("inspect pod state with 'container exec \(containerId) kubectl get pods -n kube-system'")
        throw ContainerizationError(
            .timeout,
            message: "cluster \(containerId) kube-system pods did not become available within \(podReadyTimeout * 2)s"
        )
    }
}
