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

@testable import ContainerK8s

struct K8sNodeImageVersionTests {
    @Test
    func versionComesFromTheGivenImage() throws {
        #expect(try K8sHelper.kubernetesVersion(nodeImage: "docker.io/kindest/node:v1.34.11") == "v1.34.11")
    }

    @Test
    func versionComesFromTagWhenDigestIsPresent() throws {
        let image = "docker.io/kindest/node:v1.34.11@sha256:0000000000000000000000000000000000000000000000000000000000000000"
        #expect(try K8sHelper.kubernetesVersion(nodeImage: image) == "v1.34.11")
    }

    @Test
    func defaultImageStillResolves() throws {
        #expect(try K8sHelper.kubernetesVersion(nodeImage: K8sHelper.nodeImage) == "v1.35.5")
    }

    @Test
    func untaggedImageThrows() {
        #expect(throws: (any Error).self) {
            try K8sHelper.kubernetesVersion(nodeImage: "docker.io/kindest/node")
        }
    }

    @Test
    func digestOnlyImageThrows() {
        let image = "docker.io/kindest/node@sha256:0000000000000000000000000000000000000000000000000000000000000000"
        #expect(throws: (any Error).self) {
            try K8sHelper.kubernetesVersion(nodeImage: image)
        }
    }
}
