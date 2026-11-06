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

import ContainerTestSupport
import Foundation
import SystemPackage
import Testing
import Yams

@Suite(.serialized)
struct TestClusterStartStopSerial {
    private func expectAllNodesReady(_ f: ContainerFixture, name: String) throws {
        try f.run([
            "exec", name, "kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf",
            "wait", "--for=condition=Ready", "node", "--all", "--timeout=60s",
        ]).check()
    }

    private func expectServiceDNS(_ f: ContainerFixture, name: String) throws {
        let (_, corednsStatus) = try f.kubectl(
            node: name,
            args: [
                "-n", "kube-system", "wait", "--for=condition=Available", "deployment/coredns", "--timeout=120s",
            ])
        #expect(corednsStatus == 0)

        let podImage = try f.preparePodImage()
        let podName = "dns-probe"
        let (_, createStatus) = try f.kubectl(
            node: name,
            args: [
                "run", podName,
                "--image=\(podImage.reference)",
                "--image-pull-policy=\(podImage.pullPolicy)",
                "--restart=Never",
                "--", "sleep", "300",
            ])
        #expect(createStatus == 0)
        try f.waitForPod(node: name, podName: podName, timeoutSeconds: 300)

        let (output, execStatus) = try f.kubectl(
            node: name,
            args: ["exec", podName, "--", "nslookup", "kubernetes.default.svc.cluster.local"])
        if execStatus != 0 {
            dumpDNSFailureState(f, name: name, podName: podName)
        }
        #expect(execStatus == 0)
        #expect(output.contains("Address"))
    }

    private func kubectlInCluster(_ f: ContainerFixture, name: String, _ args: [String]) -> String {
        let command = ["exec", name, "kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf"] + args
        guard let result = try? f.run(command) else {
            return "(command failed to run)"
        }
        return "exit=\(result.status)\n\(result.output)\(result.error)"
    }

    /// Prints cluster and node state after a failed lookup, then retries the lookup every 5 seconds for a minute.
    private func dumpDNSFailureState(_ f: ContainerFixture, name: String, podName: String) {
        print("=== DNS FAILURE STATE [\(name)] ===")
        let queries: [[String]] = [
            ["get", "nodes", "-o", "wide"],
            ["-n", "kube-system", "get", "pods", "-o", "wide"],
            ["get", "pod", podName, "-o", "wide"],
            ["get", "endpoints", "kubernetes"],
            ["-n", "kube-system", "get", "endpoints", "kube-dns"],
            ["-n", "kube-system", "logs", "-l", "k8s-app=kube-proxy", "--tail=15", "--prefix"],
            ["-n", "kube-system", "logs", "-l", "app=kindnet", "--tail=10", "--prefix"],
            ["exec", podName, "--", "cat", "/etc/resolv.conf"],
        ]
        for query in queries {
            print("[kubectl \(query.joined(separator: " "))]\n\(kubectlInCluster(f, name: name, query))")
        }

        let nodeNames = kubectlInCluster(f, name: name, ["get", "nodes", "-o", "name"])
            .split(separator: "\n")
            .filter { $0.hasPrefix("node/") }
            .map { String($0.dropFirst("node/".count)) }
        let nodeCommands: [[String]] = [
            ["date", "-u"],
            ["ip", "-4", "route"],
            ["sh", "-c", "iptables-save -t nat | grep -E '10.96.0.10' | head -15"],
            ["sh", "-c", "journalctl -b -u kubelet --no-pager | grep -E 'no such host|Unable to register|Successfully registered' | tail -6 | cut -c1-200"],
        ]
        for node in nodeNames {
            for command in nodeCommands {
                guard let result = try? f.run(["exec", node] + command) else {
                    continue
                }
                print("[\(node): \(command.joined(separator: " "))] exit=\(result.status)\n\(result.output)\(result.error)")
            }
        }

        for attempt in 1...12 {
            Thread.sleep(forTimeInterval: 5)
            let retry = kubectlInCluster(
                f, name: name,
                ["exec", podName, "--", "nslookup", "-timeout=3", "kubernetes.default.svc.cluster.local"])
            let recovered = retry.hasPrefix("exit=0")
            print("[dns retry \(attempt), +\(attempt * 5)s] \(recovered ? "recovered" : "still failing")")
            if recovered {
                break
            }
        }
        print("=== END DNS FAILURE STATE ===")
    }

    private func clusterState(_ f: ContainerFixture, name: String) throws -> String {
        let list = try f.run(["cluster", "list", "--format", "json"]).check()
        guard let clusters = try JSONSerialization.jsonObject(with: list.outputData) as? [[String: Any]] else {
            throw CommandError.executionFailed("cluster list output is not a JSON array")
        }
        for cluster in clusters {
            let configuration = cluster["configuration"] as? [String: Any]
            guard configuration?["name"] as? String == name else {
                continue
            }
            guard let status = cluster["status"] as? [String: Any], let state = status["state"] as? String else {
                throw CommandError.executionFailed("cluster \(name) has no status.state")
            }
            return state
        }
        throw CommandError.executionFailed("cluster \(name) not found in cluster list output")
    }

    private func startedDate(_ f: ContainerFixture, name: String) throws -> String {
        let inspect = try f.run(["inspect", name]).check()
        guard let containers = try JSONSerialization.jsonObject(with: inspect.outputData) as? [[String: Any]],
            let status = containers.first?["status"] as? [String: Any],
            let startedDate = status["startedDate"] as? String
        else {
            throw CommandError.executionFailed("inspect output for \(name) has no status.startedDate")
        }
        return startedDate
    }

    private func expectKubeconfigEntries(named name: String) throws {
        let path = FilePath(FileManager.default.homeDirectoryForCurrentUser.path).appending(".kube").appending("config")
        let yaml = try String(contentsOfFile: path.string, encoding: .utf8)
        guard let kubeconfig = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw CommandError.executionFailed("could not parse kubeconfig at \(path.string)")
        }
        for section in ["clusters", "contexts", "users"] {
            let entries = (kubeconfig[section] as? [[String: Any]]) ?? []
            #expect(entries.contains { $0["name"] as? String == name }, "\(section) is missing \(name)")
        }
    }

    @Test func testStopThenStartSingleNode() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            try f.createCluster(name: name, args: ContainerFixture.sharedImageStoreArgs)

            let stop = try f.run(["cluster", "stop", "--name", name])
            try stop.check()
            #expect(stop.output.contains(name))
            #expect(try f.getContainerStatus(name) == "stopped")
            try expectKubeconfigEntries(named: name)

            #expect(try clusterState(f, name: name) == "stopped")

            let start = try f.run(["cluster", "start", "--name", name])
            if start.status != 0 {
                f.dumpNodeDiagnostics(node: name)
            }
            try start.check()
            #expect(try f.getContainerStatus(name) == "running")
            try expectKubeconfigEntries(named: name)
            try expectAllNodesReady(f, name: name)
            try expectServiceDNS(f, name: name)
        }
    }

    @Test func testStartRunningClusterIsNoOp() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            try f.createCluster(name: name, args: ContainerFixture.sharedImageStoreArgs)

            let startedBefore = try startedDate(f, name: name)
            let start = try f.run(["cluster", "start", "--name", name])
            try start.check()
            #expect(start.output.contains(name))
            #expect(try startedDate(f, name: name) == startedBefore)
        }
    }

    @Test func testStopThenStartMultiNode() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let worker = "\(name)-worker-1"
            try f.createCluster(name: name, args: ContainerFixture.sharedImageStoreArgs + ["--workers", "1"])

            try f.run(["cluster", "stop", "--name", name]).check()
            #expect(try f.getContainerStatus(name) == "stopped")
            #expect(try f.getContainerStatus(worker) == "stopped")

            try f.run(["cluster", "start", "--name", name]).check()
            #expect(try f.getContainerStatus(name) == "running")
            #expect(try f.getContainerStatus(worker) == "running")
            try expectAllNodesReady(f, name: name)
            try expectServiceDNS(f, name: name)
        }
    }
}
