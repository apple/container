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
struct TestClusterCNISerial {

    @Test func testCreateWithCNINoneSkipsCNIInstallation() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let result = try f.createCluster(name: name, args: ["--cni", "NONE"])
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
