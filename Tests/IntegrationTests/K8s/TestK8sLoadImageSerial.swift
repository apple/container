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
struct TestK8sLoadImageSerial {

    private static let testImage = WarmupImage.alpine320.rawValue

    private func dumpNodeDiagnostics(_ f: ContainerFixture, node: String) {
        print("=== NODE DIAGNOSTICS [\(node)] ===")
        let cmds: [(label: String, args: [String])] = [
            ("ip-link", ["ip", "link", "show"]),
            ("iptables-mss", ["iptables", "-t", "mangle", "-L", "-n", "-v"]),
            ("containerd", ["systemctl", "status", "containerd", "--no-pager", "-l"]),
            ("kubelet-log", ["journalctl", "-u", "kubelet", "--no-pager", "-n", "60"]),
            ("crictl-images", ["crictl", "images"]),
        ]
        for (label, args) in cmds {
            if let r = try? f.run(["exec", node] + args) {
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let err = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[\(label)] exit=\(r.status)")
                if !out.isEmpty { print(out) }
                if !err.isEmpty { print("stderr: \(err)") }
            }
        }
        print("=== END NODE DIAGNOSTICS ===")
    }

    private func imageExistsInNode(_ f: ContainerFixture, node: String, image: String) throws -> Bool {
        print("[k8s-load] ctr images list (node: \(node), checking: \(image))")
        let result = try f.run(["exec", node, "ctr", "--namespace", "k8s.io", "images", "list"])
        print("[k8s-load] ctr images list exit=\(result.status) found=\(result.output.contains(image))")
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
            let name = "k8s-\(f.testID)"
            f.addCleanup { _ = try? f.run(["k8s", "delete", "--name", name]) }

            print("[k8s-load] k8s create --name \(name)")
            let result = try f.run(["k8s", "create", "--name", name])
            print("[k8s-load] k8s create exit=\(result.status)")
            if result.status != 0 {
                print("[k8s-load] k8s create stderr: \(result.error)")
                dumpEnv(f, clusterName: name)
                dumpNodeDiagnostics(f, node: name)
            }
            try result.check()

            print("[k8s-load] pulling \(Self.testImage)")
            try f.doPull(Self.testImage)

            print("[k8s-load] k8s load-image --name \(name) \(Self.testImage)")
            let loadResult = try f.run(["k8s", "load-image", "--name", name, Self.testImage])
            print("[k8s-load] k8s load-image exit=\(loadResult.status)")
            if loadResult.status != 0 {
                print("[k8s-load] load-image stderr: \(loadResult.error)")
            }
            #expect(loadResult.status == 0)

            #expect(try imageExistsInNode(f, node: name, image: "alpine"))
        }
    }
}
