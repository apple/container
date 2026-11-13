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

@testable import ContainerCluster

@Suite("ClusterCreate --kubernetes-version flag")
struct ClusterCreateKubernetesVersionTests {
    @Test func defaultsToTheNewestSupportedImage() throws {
        #expect(try ClusterCreate.parse([]).resolvedNodeImage == ClusterHelper.supportedVersions[0].nodeImage)
    }

    @Test(arguments: ClusterHelper.supportedVersions)
    func eachSupportedVersionSelectsItsImage(entry: ClusterHelper.SupportedVersion) throws {
        #expect(try ClusterCreate.parse(["--kubernetes-version", entry.kubernetesVersion]).resolvedNodeImage == entry.nodeImage)
        #expect(try ClusterCreate.parse(["--kubernetes-version", "v\(entry.kubernetesVersion)"]).resolvedNodeImage == entry.nodeImage)
    }

    @Test func nodeImageIsUsedAsGiven() throws {
        let image = "docker.io/kindest/node:v1.34.11"
        #expect(try ClusterCreate.parse(["--node-image", image]).resolvedNodeImage == image)
    }

    @Test func unsupportedVersionIsRejected() {
        #expect(throws: (any Error).self) { try ClusterCreate.parse(["--kubernetes-version", "1.20"]) }
    }

    @Test func versionAndNodeImageCantBeCombined() {
        #expect(throws: (any Error).self) {
            try ClusterCreate.parse(["--kubernetes-version", "1.36", "--node-image", "docker.io/kindest/node:v1.36.4"])
        }
    }

    @Test func supportedImagesAreRecognized() {
        for entry in ClusterHelper.supportedVersions {
            #expect(ClusterHelper.isSupported(nodeImage: entry.nodeImage))
        }
        #expect(!ClusterHelper.isSupported(nodeImage: "docker.io/kindest/node:v1.34.11"))
    }
}
