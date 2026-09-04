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
struct TestK8sRunSerial {

    private func loadKubeconfig() throws -> [String: Any] {
        let path = FilePath(FileManager.default.homeDirectoryForCurrentUser.path)
            .appending(".kube")
            .appending("config")
        let yaml = try String(contentsOfFile: path.string, encoding: .utf8)
        guard let parsed = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw CommandError.executionFailed("could not parse kubeconfig at \(path.string)")
        }
        return parsed
    }

    // The apiserver address in the kubeconfig is either a host-port mapping
    // (https://127.0.0.1:<port>) or, when a DNS domain is configured
    // system-wide, an FQDN (https://<name>.<domain>:6443) with no published
    // port at all. Reading it back from the kubeconfig is correct either way.
    private func serverAddress(for name: String, in kubeconfig: [String: Any]) -> String? {
        let clusters = (kubeconfig["clusters"] as? [[String: Any]]) ?? []
        guard let entry = clusters.first(where: { $0["name"] as? String == name }) else { return nil }
        return (entry["cluster"] as? [String: Any])?["server"] as? String
    }

    @Test func testRunSingleNode() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-run] k8s create --name \(name)")
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-run] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-run] k8s create stderr: \(result.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try result.check()
            #expect(result.output.contains(name))

            let containerStatus = try f.getContainerStatus(name)
            print("[k8s-run] container status=\(containerStatus)")
            #expect(containerStatus == "running")

            let kubeconfig = try loadKubeconfig()

            let clusters = (kubeconfig["clusters"] as? [[String: Any]]) ?? []
            #expect(clusters.contains { $0["name"] as? String == name })

            let contexts = (kubeconfig["contexts"] as? [[String: Any]]) ?? []
            #expect(contexts.contains { $0["name"] as? String == name })

            let users = (kubeconfig["users"] as? [[String: Any]]) ?? []
            #expect(users.contains { $0["name"] as? String == name })
        }
    }

    @Test func testConcurrentCreateGetsDifferentServerAddresses() async throws {
        try await ContainerFixture.with { f in
            let name1 = "k8s-\(f.testID)-a"
            let name2 = "k8s-\(f.testID)-b"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name1]) }
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name2]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-run] k8s create --name \(name1)")
            let result1 = try f.run(["k8s", "create", "--name", name1])
            print("[k8s-run] k8s create exit=\(result1.status)")
            if result1.status != 0 {
                print("[k8s-run] k8s create stderr: \(result1.error)")
                f.dumpNodeDiagnostics(node: name1)
            }
            #expect(result1.status == 0)

            print("[k8s-run] k8s create --name \(name2)")
            let result2 = try f.run(["k8s", "create", "--name", name2])
            print("[k8s-run] k8s create exit=\(result2.status)")
            if result2.status != 0 {
                print("[k8s-run] k8s create stderr: \(result2.error)")
                f.dumpNodeDiagnostics(node: name2)
            }
            #expect(result2.status == 0)

            #expect(try f.getContainerStatus(name1) == "running")
            #expect(try f.getContainerStatus(name2) == "running")

            let kubeconfig = try loadKubeconfig()
            let server1 = serverAddress(for: name1, in: kubeconfig)
            let server2 = serverAddress(for: name2, in: kubeconfig)
            print("[k8s-run] server1=\(server1 ?? "nil") server2=\(server2 ?? "nil")")
            #expect(server1 != nil)
            #expect(server2 != nil)
            #expect(server1 != server2)
        }
    }

    @Test func testRestartAfterAddressRotation() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            let bumper = "\(name)-bumper"
            f.addCleanup { try f.doRemoveIfExists(bumper, force: true, ignoreFailure: true) }
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            try f.run(["k8s", "create", "--name", name]).check()

            let originalAddress = try f.run(["exec", name, "cat", "/kind/old-ipv4"])
            try originalAddress.check()
            #expect(try f.run(["exec", name, "test", "-f", "/kind/kubeadm.conf"]).status == 0)
            try f.run([
                "exec", name, "grep", "-F", "controlPlaneEndpoint: 127.0.0.1:6443", "/kind/kubeadm.conf",
            ]).check()

            try f.run(["stop", name]).check()
            // Advance the rotating allocator while the node is stopped so its
            // restart cannot accidentally reuse the same address.
            try f.restoreWarmupImage(.alpine320)
            try f.run([
                "run", "--name", bumper, "-d", WarmupImage.alpine320.rawValue,
                "sleep", "infinity",
            ]).check()

            let restart = try f.run(["k8s", "start", "--name", name])
            if restart.status != 0 {
                print("[k8s-run] restart stderr: \(restart.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try restart.check()

            let rotatedAddress = try f.run(["exec", name, "cat", "/kind/old-ipv4"])
            try rotatedAddress.check()
            let originalIP = originalAddress.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let rotatedIP = rotatedAddress.output.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[k8s-run] restart rotated address \(originalIP) -> \(rotatedIP)")
            #expect(originalIP != rotatedIP)
            #expect(try f.getContainerStatus(name) == "running")
            try f.run([
                "exec", name, "grep", "-F", "advertiseAddress: \(rotatedIP)", "/kind/kubeadm.conf",
            ]).check()
            try f.run([
                "exec", name, "kubectl", "wait", "--for=condition=Ready", "node", "--all", "--timeout=30s",
            ]).check()
        }
    }
}
