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

@Suite("ClusterCreate --shared-image-store flag")
struct ClusterSharedImageStoreOptionTests {
    @Test func sharingIsOffByDefault() throws {
        let command = try ClusterCreate.parse([])
        #expect(!command.sharedImageStore)
    }

    @Test func flagTurnsSharingOn() throws {
        let command = try ClusterCreate.parse(["--shared-image-store"])
        #expect(command.sharedImageStore)
    }

    @Test func valueIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try ClusterCreate.parse(["--shared-image-store=false"])
        }
    }
}

@Suite("ClusterHelper.initConfigYAML image service")
struct InitConfigImageServiceTests {
    let nodeImage = "docker.io/kindest/node:v1.35.5"

    @Test func sharingSetsKubeletImageService() throws {
        let yaml = try ClusterHelper.initConfigYAML(
            nodeImage: nodeImage, advertiseAddress: "192.168.64.2", certSANs: ["127.0.0.1"], sharedImageStore: true)
        #expect(yaml.contains("imageServiceEndpoint: unix:///run/cluster-shim/cri-image.sock"))
    }

    @Test func noSharingLeavesKubeletImageServiceUnset() throws {
        let yaml = try ClusterHelper.initConfigYAML(
            nodeImage: nodeImage, advertiseAddress: "192.168.64.2", certSANs: ["127.0.0.1"], sharedImageStore: false)
        #expect(!yaml.contains("imageServiceEndpoint"))
        #expect(yaml.hasSuffix("failSwapOn: false"))
    }
}
