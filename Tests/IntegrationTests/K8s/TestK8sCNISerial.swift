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

    @Test func testCreateWithCNINoneSkipsCNIInstallation() async throws {
        try await ContainerFixture.with { f in
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[k8s-cni] k8s create --name \(name) --cni none")
            let result = try f.run(["k8s", "create", "--name", name, "--cni", "none"])
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
