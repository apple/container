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
struct TestClusterLoadImageSerial {

    private static let testImage = WarmupImage.alpine320.rawValue

    private func imageExistsInNode(_ f: ContainerFixture, node: String, image: String) throws -> Bool {
        print("[cluster-load] ctr images list (node: \(node), checking: \(image))")
        let result = try f.run(["exec", node, "ctr", "--namespace", "k8s.io", "images", "list"])
        print("[cluster-load] ctr images list exit=\(result.status) found=\(result.output.contains(image))")
        guard result.status == 0 else { return false }
        return result.output.contains(image)
    }

    private func dumpEnv(_ f: ContainerFixture, clusterName: String) {
        print("=== ENV DUMP [\(clusterName)] ===")
        if let result = try? f.run(["system", "status"]) {
            print("[system status]\n\(result.output)")
        }
        if let result = try? f.run(["list"]) {
            print("[container list]\n\(result.output)")
        }
        if let result = try? f.run(["image", "list"]) {
            print("[image list]\n\(result.output)")
        }
        if let result = try? f.run(["inspect", clusterName]) {
            print("[inspect \(clusterName)]\nstdout: \(result.output)\nstderr: \(result.error)")
        }
        print("=== END ENV DUMP ===")
    }

    @Test func testLoadImageIntoSingleNode() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            print("[cluster-load] cluster create --name \(name)")
            let result = try f.run(["cluster", "create", "--name", name])
            print("[cluster-load] cluster create exit=\(result.status)")
            if result.status != 0 {
                print("[cluster-load] cluster create stderr: \(result.error)")
                dumpEnv(f, clusterName: name)
                f.dumpNodeDiagnostics(node: name)
            }
            try result.check()

            print("[cluster-load] pulling \(Self.testImage)")
            try f.restoreWarmupImage(.alpine320)

            print("[cluster-load] cluster load-image --name \(name) \(Self.testImage)")
            let loadResult = try f.run(["cluster", "load-image", "--name", name, Self.testImage])
            print("[cluster-load] cluster load-image exit=\(loadResult.status)")
            if loadResult.status != 0 {
                print("[cluster-load] load-image stderr: \(loadResult.error)")
            }
            #expect(loadResult.status == 0)

            #expect(try imageExistsInNode(f, node: name, image: "alpine"))
        }
    }

    @Test func testLoadImageReferenceForms() async throws {
        try await ContainerFixture.with { f in
            let name = "cluster-\(f.testID)"
            let sourceImage = Self.testImage
            let images = [
                "img-\(f.testID)",
                "img-\(f.testID):v1",
                "org-\(f.testID)/img",
                "docker.io/hub-\(f.testID)",
                "ghcr.io/org/img-\(f.testID):v1",
            ]
            f.addCleanup { _ = try? f.run(["cluster", "delete", "--name", name]) }
            f.addCleanup { try? f.doRemoveImages(images) }

            try f.restoreWarmupImage(.kindestNodeV1_35_5)
            try f.run(["cluster", "create", "--name", name]).check()

            try f.restoreWarmupImage(.alpine320)
            for image in images {
                try f.doImageTag(sourceImage, newName: image)
                let fullImage = try f.inspectImage(image)

                try f.run(["cluster", "load-image", "--name", name, image]).check()

                #expect(try imageExistsInNode(f, node: name, image: fullImage))
            }
        }
    }
}
