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
struct TestK8sCNISerial {

    @Test func testCreateStreamsOversizedCNIManifest() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let kindnetURL = repositoryRoot.appendingPathComponent("Sources/Plugins/K8s/Resources/kindnet.yaml")
            let kindnet = try String(contentsOf: kindnetURL, encoding: .utf8)
            let payload = String(repeating: "a", count: 150_000)
            let manifest =
                kindnet
                    + """

                    ---
                    apiVersion: v1
                    kind: ConfigMap
                    metadata:
                      name: stdin-regression
                      namespace: kube-system
                    data:
                      payload: \(payload)
                    """
            let manifestPath = f.testDir.appending("oversized-cni.yaml").string
            try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)
            #expect(Data(manifest.utf8).count > 128 * 1024)

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            let result = try f.run(["k8s", "create", "--name", name, "--cni", manifestPath])
            if result.status != 0 {
                f.dumpNodeDiagnostics(node: name)
            }

            try result.check()
            let (output, status) = try f.kubectl(
                node: name,
                args: ["get", "configmap", "stdin-regression", "-n", "kube-system", "-o", "name"])
            #expect(status == 0)
            #expect(output.contains("configmap/stdin-regression"))
        }
    }

    @Test func testCreateWithCNINoneSkipsCNIInstallation() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-cni] k8s create --name \(name) --cni NONE")
            let result = try f.run(["k8s", "create", "--name", name, "--cni", "NONE"])
            print("[k8s-cni] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-cni] k8s create stderr: \(result.error)")
                f.dumpNodeDiagnostics(node: name)
            }

            try result.check()
            #expect(result.output.contains(name))
            #expect(try f.getContainerStatus(name) == "running")

            // No CNI manifest was applied, so kube-system has no CNI daemonset and the node never reaches Ready.
            let (podsOutput, podsStatus) = try f.kubectl(node: name, args: ["get", "pods", "-n", "kube-system", "--no-headers"])
            #expect(podsStatus == 0)
            #expect(!podsOutput.lowercased().contains("kindnet"))

            let (nodesOutput, nodesStatus) = try f.kubectl(node: name, args: ["get", "nodes", "--no-headers"])
            #expect(nodesStatus == 0)
            #expect(nodesOutput.contains("NotReady"))
        }
    }
}
