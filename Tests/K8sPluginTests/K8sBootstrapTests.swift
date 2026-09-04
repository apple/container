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

import Testing
import Yams

@testable import ContainerK8s

@Suite("K8s bootstrap configuration")
struct K8sBootstrapTests {
    @Test func nodeLocalEndpointUsesClusterPort() {
        #expect(K8sHelper.nodeLocalControlPlaneEndpoint == "127.0.0.1:6443")
    }

    @Test func nodeLocalControlPlaneEndpointIsRendered() {
        let yaml = K8sHelper.initConfigYAML(
            advertiseAddress: "192.168.64.2",
            certSANs: ["127.0.0.1"],
            controlPlaneEndpoint: K8sHelper.nodeLocalControlPlaneEndpoint)

        #expect(yaml.contains("controlPlaneEndpoint: 127.0.0.1:6443"))
        #expect(yaml.contains("advertiseAddress: 192.168.64.2"))
        #expect(yaml.contains("  - 127.0.0.1"))
        for document in yaml.components(separatedBy: "\n---\n") {
            #expect((try? Yams.load(yaml: document)) != nil)
        }
    }
}
