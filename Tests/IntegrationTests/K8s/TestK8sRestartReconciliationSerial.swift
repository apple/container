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

/// Covers the `container stop` -> `container k8s start` cycle: the node's IP
/// can change across that cycle, and the entrypoint's reconciliation logic is
/// what keeps the apiserver cert, kubeadm-managed config files, and kubeconfig
/// consistent with whatever address the node comes back up with.
@Suite(.serialized)
struct TestK8sRestartReconciliationSerial {

    private func execOutput(_ f: ContainerFixture, node: String, _ args: [String]) throws -> (status: Int32, output: String, error: String) {
        let r = try f.run(["exec", node] + args)
        return (r.status, r.output.trimmingCharacters(in: .whitespacesAndNewlines), r.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func nodeIPv4Address(_ f: ContainerFixture, node: String) throws -> String? {
        let (_, out, _) = try execOutput(
            f, node: node,
            [
                "sh", "-c",
                #"""
                DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
                if [ -n "$DEFAULT_IFACE" ]; then
                    ip -4 -o addr show dev "$DEFAULT_IFACE" | awk '{print $4}' | head -1 | cut -d/ -f1
                else
                    ip -4 -o addr show | awk '$2 != "lo" && $2 !~ /^veth/ {print $4}' | head -1 | cut -d/ -f1
                fi
                """#,
            ])
        return out.isEmpty ? nil : out
    }

    private func kubectlGetNodesReady(_ f: ContainerFixture, node: String) throws -> Bool {
        let (status, out, _) = try execOutput(
            f, node: node,
            ["sh", "-c", "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers"])
        return status == 0 && out.contains(" Ready")
    }

    @Test func testClusterSurvivesStopAndK8sStart() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-restart] k8s create --name \(name)")
            let createResult = try f.run(["k8s", "create", "--name", name])
            if createResult.status != 0 {
                print("[k8s-restart] k8s create stderr: \(createResult.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try createResult.check()
            #expect(try f.getContainerStatus(name) == "running")
            #expect(try kubectlGetNodesReady(f, node: name))

            let ipBeforeStop = try nodeIPv4Address(f, node: name)
            print("[k8s-restart] address before stop: \(ipBeforeStop ?? "nil")")
            #expect(ipBeforeStop != nil)

            print("[k8s-restart] container stop \(name)")
            try f.doStop(name, signal: nil)
            #expect(try f.getContainerStatus(name) == "stopped")

            print("[k8s-restart] k8s start --name \(name)")
            let startResult = try f.run(["k8s", "start", "--name", name])
            print("[k8s-restart] k8s start exit=\(startResult.status)")
            if startResult.status != 0 {
                print("[k8s-restart] k8s start stderr: \(startResult.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try startResult.check()
            #expect(try f.getContainerStatus(name) == "running")

            let ipAfterStart = try nodeIPv4Address(f, node: name)
            print("[k8s-restart] address after start: \(ipAfterStart ?? "nil")")
            #expect(ipAfterStart != nil)

            // The cluster must be reachable regardless of whether the address
            // actually changed across this cycle -- this is the end-to-end
            // assertion the reconciliation logic exists to guarantee.
            #expect(try kubectlGetNodesReady(f, node: name))

            // admin.conf is what container k8s copies to /root/.kube/config and
            // is the source `fetchConfig` reads to build the host kubeconfig.
            // If reconciliation didn't patch it, this will still contain the
            // pre-stop address.
            let (_, adminConf, _) = try execOutput(f, node: name, ["cat", "/etc/kubernetes/admin.conf"])
            if let ip = ipAfterStart {
                #expect(adminConf.contains(ip), "admin.conf does not reference the node's current address (\(ip))")
            }

            // Same check against the file `kubeadm init phase certs apiserver`
            // itself reads during reconciliation -- if this still has the old
            // address, cert regeneration would have reused it.
            let (_, kubeadmConfig, _) = try execOutput(f, node: name, ["cat", "/etc/kubernetes/kubeadm-config.yaml"])
            if let ip = ipAfterStart {
                #expect(kubeadmConfig.contains(ip), "kubeadm-config.yaml does not reference the node's current address (\(ip))")
            }
            if let ip = ipBeforeStop, ip != ipAfterStart {
                print("[k8s-restart] address changed across stop/start: \(ip) -> \(ipAfterStart ?? "nil")")
                #expect(!kubeadmConfig.contains(ip), "kubeadm-config.yaml still references the stale pre-stop address (\(ip))")
            }
        }
    }

    @Test func testApiserverCertificateIsPresentAfterStopAndStart() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let createResult = try f.run(["k8s", "create", "--name", name])
            if createResult.status != 0 {
                f.dumpNodeDiagnostics(node: name)
            }
            try createResult.check()

            try f.doStop(name, signal: nil)
            let startResult = try f.run(["k8s", "start", "--name", name])
            if startResult.status != 0 {
                print("[k8s-restart] k8s start stderr: \(startResult.error)")
                f.dumpNodeDiagnostics(node: name)
            }
            try startResult.check()

            // Regression guard for the createContainer hook / DMI-fake removal:
            // an apiserver that fails to start after a restart shows up here as
            // a missing cert file, not just a failed kubectl call.
            let (certStatus, certOut, _) = try execOutput(f, node: name, ["test", "-f", "/etc/kubernetes/pki/apiserver.crt"])
            #expect(certStatus == 0, "apiserver.crt missing after stop/start: \(certOut)")

            #expect(try kubectlGetNodesReady(f, node: name))
        }
    }

    @Test func testStaticPodsAreRunningAfterStopAndStart() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let createResult = try f.run(["k8s", "create", "--name", name])
            if createResult.status != 0 {
                f.dumpNodeDiagnostics(node: name)
            }
            try createResult.check()

            try f.doStop(name, signal: nil)
            let startResult = try f.run(["k8s", "start", "--name", name])
            if startResult.status != 0 {
                f.dumpNodeDiagnostics(node: name)
            }
            try startResult.check()

            // Regression guard for the createContainer hook crash: when the
            // hook fails, every static pod container (etcd, apiserver,
            // controller-manager, scheduler) is stuck Exited, not just apiserver.
            let (status, out, _) = try execOutput(f, node: name, ["crictl", "ps", "-a"])
            #expect(status == 0)
            for podName in ["etcd", "kube-apiserver", "kube-controller-manager", "kube-scheduler"] {
                let line = out.split(separator: "\n").first { $0.contains(podName) }
                #expect(line != nil, "\(podName) not found in crictl ps -a output")
                if let line {
                    #expect(line.contains("Running"), "\(podName) is not Running after stop/start: \(line)")
                }
            }
        }
    }
}
