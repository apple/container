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
import Testing

@Suite(.serialized)
struct TestK8sNetworkingSerial {

    private static let testImage = WarmupImage.alpine320

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

    private func waitForPod(_ f: ContainerFixture, node: String, podName: String, timeoutSeconds: Int) throws {
        print("[k8s-net] waitForPod \(podName) on \(node) (timeout=\(timeoutSeconds)s)")
        let (_, status) = try f.kubectl(
            node: node,
            args: [
                "wait", "--for=condition=Ready", "pod/\(podName)", "--timeout=\(timeoutSeconds)s",
            ])
        guard status == 0 else {
            let (podStatus, _) = try f.kubectl(node: node, args: ["get", "pod", podName, "--no-headers"])
            print("[k8s-net] pod \(podName) status: \(podStatus.trimmingCharacters(in: .whitespacesAndNewlines))")
            let (podDesc, _) = try f.kubectl(node: node, args: ["describe", "pod", podName])
            print("[k8s-net] pod \(podName) describe:\n\(podDesc.prefix(1000))")
            throw CommandError.executionFailed("pod \(podName) did not become ready within \(timeoutSeconds)s")
        }
        print("[k8s-net] pod \(podName) is Ready")
    }

    // Verify that a pod schedules, reaches Running, and can be exec'd into.
    @Test func testPodsScheduleAndRun() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-net] k8s create --name \(name)")
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-net] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-net] k8s create stderr: \(result.error)")
                dumpEnv(f, clusterName: name)
                f.dumpNodeDiagnostics(node: name)
            }
            try result.check()

            print("[k8s-net] pulling \(Self.testImage.rawValue)")
            try f.restoreWarmupImage(Self.testImage)

            print("[k8s-net] k8s load-image --name \(name) \(Self.testImage.rawValue)")
            let loadResult = try f.run(["k8s", "load-image", "--name", name, Self.testImage.rawValue])
            print("[k8s-net] k8s load-image exit=\(loadResult.status)")
            if loadResult.status != 0 { print("[k8s-net] k8s load-image stderr: \(loadResult.error)") }
            #expect(loadResult.status == 0)

            let (_, createStatus) = try f.kubectl(
                node: name,
                args: [
                    "run", "test-pod",
                    "--image=\(Self.testImage.rawValue)",
                    "--image-pull-policy=Never",
                    "--restart=Never",
                    "--", "sleep", "300",
                ])
            #expect(createStatus == 0)

            try waitForPod(f, node: name, podName: "test-pod", timeoutSeconds: 300)

            let (output, execStatus) = try f.kubectl(
                node: name,
                args: [
                    "exec", "test-pod", "--", "echo", "hello",
                ])
            #expect(execStatus == 0)
            #expect(output.contains("hello"))
        }
    }

    // Verify pod-to-service communication and CoreDNS resolution on a single node.
    @Test func testPodToServiceCommunication() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-net] k8s create --name \(name)")
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-net] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-net] k8s create stderr: \(result.error)")
                dumpEnv(f, clusterName: name)
            }
            try result.check()

            print("[k8s-net] pulling \(Self.testImage.rawValue)")
            try f.restoreWarmupImage(Self.testImage)

            print("[k8s-net] k8s load-image --name \(name) \(Self.testImage.rawValue)")
            let loadResult = try f.run(["k8s", "load-image", "--name", name, Self.testImage.rawValue])
            print("[k8s-net] k8s load-image exit=\(loadResult.status)")
            if loadResult.status != 0 { print("[k8s-net] k8s load-image stderr: \(loadResult.error)") }
            #expect(loadResult.status == 0)

            // Server: alpine busybox httpd serving a static response.
            let (_, serverStatus) = try f.kubectl(
                node: name,
                args: [
                    "run", "server",
                    "--image=\(Self.testImage.rawValue)",
                    "--image-pull-policy=Never",
                    "--restart=Never",
                    "--port=8080",
                    "--", "sh", "-c",
                    "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok' | nc -l -p 8080; done",
                ])
            #expect(serverStatus == 0)
            try waitForPod(f, node: name, podName: "server", timeoutSeconds: 300)

            // Expose server as a ClusterIP service.
            let (_, exposeStatus) = try f.kubectl(
                node: name,
                args: [
                    "expose", "pod", "server", "--port=8080", "--name=server-svc",
                ])
            #expect(exposeStatus == 0)

            // Client pod that stays alive so we can exec into it.
            let (_, clientStatus) = try f.kubectl(
                node: name,
                args: [
                    "run", "client",
                    "--image=\(Self.testImage.rawValue)",
                    "--image-pull-policy=Never",
                    "--restart=Never",
                    "--", "sleep", "300",
                ])
            #expect(clientStatus == 0)
            try waitForPod(f, node: name, podName: "client", timeoutSeconds: 300)

            // Reach server via the service DNS name — exercises CoreDNS + kube-proxy.
            print("[k8s-net] wget from client to server-svc:8080")
            let (response, wgetStatus) = try f.kubectl(
                node: name,
                args: [
                    "exec", "client", "--", "sh", "-c",
                    "sleep 2 && wget -qO- http://server-svc:8080",
                ])
            print("[k8s-net] wget exit=\(wgetStatus) response=\(response.trimmingCharacters(in: .whitespacesAndNewlines))")
            #expect(wgetStatus == 0)
            #expect(response.contains("ok"))
        }
    }

    // Verify that the single-node endpoint used by kube-proxy stays reachable
    // when vmnet assigns the control-plane VM a different address on restart.
    @Test func testServiceNetworkingSurvivesAddressRotation() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            let bumper = "\(name)-bumper"
            f.addCleanup { try f.doRemoveIfExists(bumper, force: true, ignoreFailure: true) }
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            try f.run(["k8s", "create", "--name", name]).check()
            try f.restoreWarmupImage(Self.testImage)
            try f.run(["k8s", "load-image", "--name", name, Self.testImage.rawValue]).check()

            let (_, serverStatus) = try f.kubectl(
                node: name,
                args: [
                    "run", "server",
                    "--image=\(Self.testImage.rawValue)",
                    "--image-pull-policy=Never",
                    "--restart=Always",
                    "--port=8080",
                    "--", "sh", "-c",
                    "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok' | nc -l -p 8080; done",
                ])
            #expect(serverStatus == 0)
            try waitForPod(f, node: name, podName: "server", timeoutSeconds: 300)

            let (_, exposeStatus) = try f.kubectl(
                node: name,
                args: ["expose", "pod", "server", "--port=8080", "--name=server-svc"])
            #expect(exposeStatus == 0)

            let (_, clientStatus) = try f.kubectl(
                node: name,
                args: [
                    "run", "client",
                    "--image=\(Self.testImage.rawValue)",
                    "--image-pull-policy=Never",
                    "--restart=Always",
                    "--", "sleep", "infinity",
                ])
            #expect(clientStatus == 0)
            try waitForPod(f, node: name, podName: "client", timeoutSeconds: 300)

            let (initialResponse, initialWgetStatus) = try f.kubectl(
                node: name,
                args: ["exec", "client", "--", "wget", "-qO-", "http://server-svc:8080"])
            #expect(initialWgetStatus == 0)
            #expect(initialResponse.contains("ok"))

            let originalAddress = try f.run(["exec", name, "cat", "/etc/.container-k8s-last-ip"])
            try originalAddress.check()
            try f.run(["stop", "--time", "30", name]).check()

            // Occupy another address while the node is stopped so the restarted
            // control plane cannot accidentally receive its previous address.
            try f.run([
                "run", "--name", bumper, "--detach", Self.testImage.rawValue,
                "sleep", "infinity",
            ]).check()
            try f.run(["start", name]).check()

            // `container start` returns before the node entrypoint and API
            // server finish booting. Wait for reconciliation before reading
            // the persisted marker, then wait for the API before using kubectl.
            try await f.retry(attempts: 180) {
                guard let result = try? f.run(["exec", name, "cat", "/etc/.container-k8s-last-ip"]), result.status == 0 else {
                    return false
                }
                return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    != originalAddress.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rotatedAddress = try f.run(["exec", name, "cat", "/etc/.container-k8s-last-ip"])
            try rotatedAddress.check()
            #expect(
                originalAddress.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    != rotatedAddress.output.trimmingCharacters(in: .whitespacesAndNewlines))

            try await f.retry(attempts: 180) {
                let (ready, status) = try f.kubectl(
                    node: name, args: ["get", "--raw=/readyz", "--request-timeout=5s"])
                return status == 0 && ready.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            }
            let (_, nodeStatus) = try f.kubectl(
                node: name,
                args: ["wait", "--for=condition=Ready", "node", "--all", "--timeout=180s"])
            #expect(nodeStatus == 0)
            let (_, dnsStatus) = try f.kubectl(
                node: name,
                args: [
                    "wait", "--namespace=kube-system", "--for=condition=Ready", "pod",
                    "--selector=k8s-app=kube-dns", "--timeout=180s",
                ])
            #expect(dnsStatus == 0)
            try waitForPod(f, node: name, podName: "server", timeoutSeconds: 300)
            try waitForPod(f, node: name, podName: "client", timeoutSeconds: 300)

            let (proxyConfig, proxyConfigStatus) = try f.kubectl(
                node: name,
                args: [
                    "get", "--namespace=kube-system", "configmap/kube-proxy",
                    "--output=jsonpath={.data.kubeconfig\\.conf}",
                ])
            #expect(proxyConfigStatus == 0)
            #expect(proxyConfig.contains("server: https://127.0.0.1:6443"))

            let (response, wgetStatus) = try f.kubectl(
                node: name,
                args: ["exec", "client", "--", "wget", "-qO-", "http://server-svc:8080"])
            #expect(wgetStatus == 0)
            #expect(response.contains("ok"))
        }
    }
}
