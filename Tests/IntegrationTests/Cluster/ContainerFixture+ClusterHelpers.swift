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

extension ContainerFixture {
    /// Whether the build under test ships cluster-shim, next to the CLI in libexec.
    static var clusterShimInstalled: Bool {
        let cli: URL
        if let path = ProcessInfo.processInfo.environment["CONTAINER_CLI_PATH"] {
            cli = URL(filePath: path)
        } else {
            cli = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "bin/container")
        }
        let root = cli.deletingLastPathComponent().deletingLastPathComponent()
        let shim = root.appending(path: "libexec/container/plugins/cluster/resources/cluster-shim")
        return FileManager.default.fileExists(atPath: shim.path)
    }

    /// Creates a cluster from the warmed-up kind node image and registers its deletion as cleanup.
    /// If creation fails, dumps environment and node diagnostics before throwing.
    @discardableResult
    func createCluster(name: String, args: [String] = []) throws -> CommandResult {
        addCleanup { _ = try? self.run(["cluster", "delete", "--name", name]) }

        try restoreWarmupImage(.kindestNodeV1_35_5)
        let command = ["cluster", "create", "--name", name] + args
        print("[cluster] \(command.joined(separator: " "))")
        let result = try run(command)
        print("[cluster] cluster create exit=\(result.status)")
        if result.status != 0 {
            print("[cluster] cluster create stderr: \(result.error)")
            dumpEnvDiagnostics(clusterName: name)
            dumpNodeDiagnostics(node: name)
        }
        return try result.check()
    }

    @discardableResult
    func kubectl(node: String, args: [String]) throws -> (output: String, status: Int32) {
        print("[cluster] kubectl \(args.joined(separator: " ")) (node: \(node))")
        let result = try self.run(["exec", node, "kubectl"] + args)
        print("[cluster] kubectl exit=\(result.status) output=\(result.output.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines))")
        let filteredStderr = result.error.components(separatedBy: "\n")
            .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
            .joined(separator: "\n")
        if !filteredStderr.isEmpty {
            print("[cluster] kubectl stderr: \(filteredStderr.prefix(300))")
        }
        return (result.output, result.status)
    }

    private static let testImage = WarmupImage.alpine320
    /// A name only the host image store has, so pods can start only through cluster-shim.
    private static let hostOnlyImage = "cluster-test/alpine:host-only"

    /// Shares the local image store with the cluster when the build includes cluster-shim.
    static var sharedImageStoreArgs: [String] {
        guard ContainerFixture.clusterShimInstalled else {
            print("[cluster-net] no cluster-shim in this build; testing without the shared image store")
            return []
        }
        return ["--shared-image-store"]
    }

    /// Makes the test image available to pods and returns the reference and pull
    /// policy to use. With cluster-shim, pods use a name only the host has.
    func preparePodImage() throws -> (reference: String, pullPolicy: String) {
        print("[cluster-net] pulling \(Self.testImage.rawValue)")
        try restoreWarmupImage(Self.testImage)
        guard ContainerFixture.clusterShimInstalled else {
            return (Self.testImage.rawValue, "IfNotPresent")
        }
        try run(["image", "tag", Self.testImage.rawValue, Self.hostOnlyImage]).check()
        return (Self.hostOnlyImage, "Never")
    }

    func waitForPod(node: String, podName: String, timeoutSeconds: Int) throws {
        print("[cluster-net] waitForPod \(podName) on \(node) (timeout=\(timeoutSeconds)s)")
        let (_, status) = try kubectl(
            node: node,
            args: [
                "wait", "--for=condition=Ready", "pod/\(podName)", "--timeout=\(timeoutSeconds)s",
            ])
        guard status == 0 else {
            let (podStatus, _) = try kubectl(node: node, args: ["get", "pod", podName, "--no-headers"])
            print("[cluster-net] pod \(podName) status: \(podStatus.trimmingCharacters(in: .whitespacesAndNewlines))")
            let (podDesc, _) = try kubectl(node: node, args: ["describe", "pod", podName])
            print("[cluster-net] pod \(podName) describe:\n\(podDesc.prefix(1000))")
            throw CommandError.executionFailed("pod \(podName) did not become ready within \(timeoutSeconds)s")
        }
        print("[cluster-net] pod \(podName) is Ready")
    }
}
