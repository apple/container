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
struct TestK8sWriteConfigSerial {

    private func dumpNodeDiagnostics(_ f: ContainerFixture, node: String) {
        print("=== NODE DIAGNOSTICS [\(node)] ===")
        let cmds: [(label: String, args: [String])] = [
            ("ip-link", ["ip", "link", "show"]),
            ("iptables-mss", ["iptables", "-t", "mangle", "-L", "-n", "-v"]),
            ("containerd", ["systemctl", "status", "containerd", "--no-pager", "-l"]),
            ("kubelet-log", ["journalctl", "-u", "kubelet", "--no-pager", "-n", "60"]),
            ("crictl-images", ["crictl", "images"]),
        ]
        for (label, args) in cmds {
            if let r = try? f.run(["exec", node] + args) {
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let err = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[\(label)] exit=\(r.status)")
                if !out.isEmpty { print(out) }
                if !err.isEmpty { print("stderr: \(err)") }
            }
        }
        print("=== END NODE DIAGNOSTICS ===")
    }

    private func kubeconfigPath() -> FilePath {
        FilePath(FileManager.default.homeDirectoryForCurrentUser.path)
            .appending(".kube")
            .appending("config")
    }

    private func loadKubeconfig() throws -> [String: Any] {
        let yaml = try String(contentsOfFile: kubeconfigPath().string, encoding: .utf8)
        guard let parsed = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw CommandError.executionFailed("could not parse kubeconfig")
        }
        return parsed
    }

    private func dumpKubeconfig(for name: String) {
        let path = kubeconfigPath()
        guard FileManager.default.fileExists(atPath: path.string) else {
            print("[k8s-cfg] \(path.lastComponent?.string ?? "config") does not exist")
            return
        }
        guard let kubeconfig = try? loadKubeconfig() else {
            print("[k8s-cfg] \(path.lastComponent?.string ?? "config") could not be parsed")
            return
        }
        let clusters = (kubeconfig["clusters"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let contexts = (kubeconfig["contexts"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let current = kubeconfig["current-context"] as? String ?? "<none>"
        print("[k8s-cfg] kubeconfig: clusters=\(clusters) contexts=\(contexts) current-context=\(current)")
    }

    private func dumpEnv(_ f: ContainerFixture, clusterName: String) {
        print("=== ENV DUMP [\(clusterName)] ===")
        if let result = try? f.run(["system", "status"]) {
            print("[system status]\n\(result.output)")
        }
        if let result = try? f.run(["list"]) {
            print("[container list]\n\(result.output)")
        }
        if let result = try? f.run(["inspect", clusterName]) {
            print("[inspect \(clusterName)] stdout: \(result.output) stderr: \(result.error)")
        }
        print("=== END ENV DUMP ===")
    }

    private func kubeconfigContains(name: String) -> Bool {
        guard let kubeconfig = try? loadKubeconfig() else { return false }
        let clusters = (kubeconfig["clusters"] as? [[String: Any]]) ?? []
        return clusters.contains { $0["name"] as? String == name }
    }

    @Test func testWriteConfigMergesContext() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-cfg] k8s create --name \(name)")
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-cfg] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-cfg] k8s create stderr: \(result.error)")
                dumpEnv(f, clusterName: name)
                dumpNodeDiagnostics(f, node: name)
            }
            try result.check()

            print("[k8s-cfg] k8s write-config --name \(name)")
            let writeResult = try f.run(["k8s", "write-config", "--name", name])
            print("[k8s-cfg] k8s write-config exit=\(writeResult.status)")
            if writeResult.status != 0 {
                print("[k8s-cfg] k8s write-config stderr: \(writeResult.error)")
                dumpEnv(f, clusterName: name)
            }
            #expect(writeResult.status == 0)

            let kubeconfig = try loadKubeconfig()

            let clusters = (kubeconfig["clusters"] as? [[String: Any]]) ?? []
            #expect(clusters.contains { $0["name"] as? String == name })

            let contexts = (kubeconfig["contexts"] as? [[String: Any]]) ?? []
            #expect(contexts.contains { $0["name"] as? String == name })

            let users = (kubeconfig["users"] as? [[String: Any]]) ?? []
            #expect(users.contains { $0["name"] as? String == name })
        }
    }

    @Test func testWriteConfigIsIdempotent() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-cfg] k8s create --name \(name)")
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-cfg] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-cfg] k8s create stderr: \(result.error)")
                dumpEnv(f, clusterName: name)
                dumpNodeDiagnostics(f, node: name)
            }
            try result.check()

            print("[k8s-cfg] k8s write-config --name \(name) (first)")
            _ = try f.run(["k8s", "write-config", "--name", name])
            print("[k8s-cfg] k8s write-config --name \(name) (second)")
            let secondResult = try f.run(["k8s", "write-config", "--name", name])
            print("[k8s-cfg] k8s write-config (second) exit=\(secondResult.status)")
            #expect(secondResult.status == 0)

            let kubeconfig = try loadKubeconfig()
            let clusters = (kubeconfig["clusters"] as? [[String: Any]]) ?? []
            let matchingClusters = clusters.filter { $0["name"] as? String == name }
            #expect(matchingClusters.count == 1)
        }
    }

    @Test func testDeleteClusterCleansUpKubeconfig() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-cfg] k8s create --name \(name)")
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-cfg] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-cfg] k8s create stderr: \(result.error)")
                dumpEnv(f, clusterName: name)
                dumpNodeDiagnostics(f, node: name)
            }
            try result.check()

            print("[k8s-cfg] k8s write-config --name \(name)")
            _ = try f.run(["k8s", "write-config", "--name", name])
            #expect(kubeconfigContains(name: name))

            print("[k8s-cfg] k8s delete --name \(name)")
            let deleteResult = try f.run(["k8s", "delete", "--name", name])
            print("[k8s-cfg] k8s delete exit=\(deleteResult.status) stderr=\(deleteResult.error)")
            #expect(deleteResult.status == 0)

            #expect(!kubeconfigContains(name: name))
        }
    }
}
