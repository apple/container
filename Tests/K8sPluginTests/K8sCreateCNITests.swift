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

import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerK8s

// MARK: - K8sCreate flag parsing

@Suite("K8sCreate --cni flag")
struct K8sCreateCNIFlagTests {
    @Test func cniDefaultsToNilWhenNotProvided() throws {
        let command = try K8sCreate.parse([])
        #expect(command.cni == nil)
    }

    @Test func cniCapturesProvidedPath() throws {
        let command = try K8sCreate.parse(["--cni", "/tmp/my-cni.yaml"])
        #expect(command.cni == "/tmp/my-cni.yaml")
    }
}

// MARK: - K8sHelper CNI manifest handling

@Suite("K8sHelper.loadCNIManifest")
struct LoadCNIManifestTests {
    private let log = Logger(label: "test")

    @Test func customPathReturnsReadableFileURL() async throws {
        let contents = "kind: DaemonSet\nmetadata:\n  name: my-custom-cni\n"
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(UUID().uuidString + ".yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await K8sHelper.loadCNIManifest(path: url.path, log: log)
        #expect(result == url)
        #expect(try String(contentsOf: result, encoding: .utf8) == contents)
    }

    @Test func missingPathThrowsInvalidArgument() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-does-not-exist.yaml").path

        await #expect(throws: ContainerizationError.self) {
            _ = try await K8sHelper.loadCNIManifest(path: missingPath, log: log)
        }
    }
}

@Suite("K8sHelper.applyCNIManifest")
struct ApplyCNIManifestTests {
    @Test func streamsLargeManifestWithLiteralEOFIntact() async throws {
        let marker = "$(touch /tmp/must-not-run)"
        let contents = """
            apiVersion: v1
            kind: ConfigMap
            metadata:
              name: large-manifest
            data:
              payload: |
                \(String(repeating: "a", count: 132_000))
                EOF
                content-after-eof
                \(marker)
            """
        let expected = Data(contents.utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try expected.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = ManifestInvocationRecorder(result: (0, "configured"))
        try await K8sHelper.applyCNIManifest(manifestURL: url, nodeID: "test-node") {
            executable, arguments, environment, standardInput in
            try await recorder.execute(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput)
        }

        let invocation = await recorder.invocation
        #expect(invocation?.executable == K8sHelper.kubectlPath)
        #expect(invocation?.arguments == ["apply", "-f", "-"])
        #expect(invocation?.environment == [K8sHelper.kubeconfigEnv])
        #expect(invocation?.input == expected)
        #expect(String(decoding: invocation?.input ?? Data(), as: UTF8.self).contains("\nEOF\n"))
        #expect(String(decoding: invocation?.input ?? Data(), as: UTF8.self).contains("content-after-eof"))
        #expect(String(decoding: invocation?.input ?? Data(), as: UTF8.self).contains(marker))
    }

    @Test func failurePreservesManifestPathAndKubectlOutput() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try Data("not: [valid".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = ManifestInvocationRecorder(result: (1, "error: invalid YAML"))
        do {
            try await K8sHelper.applyCNIManifest(manifestURL: url, nodeID: "test-node") {
                executable, arguments, environment, standardInput in
                try await recorder.execute(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    standardInput: standardInput)
            }
            Issue.record("expected CNI application to fail")
        } catch let error as ContainerizationError {
            #expect(error.message.contains(url.path))
            #expect(error.message.contains("error: invalid YAML"))
        }
    }
}

private actor ManifestInvocationRecorder {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String]
        let input: Data
    }

    private(set) var invocation: Invocation?
    private let result: (code: Int32, output: String)

    init(result: (code: Int32, output: String)) {
        self.result = result
    }

    func execute(
        executable: String, arguments: [String], environment: [String], standardInput: URL?
    ) throws -> (code: Int32, output: String) {
        guard let standardInput else {
            throw ContainerizationError(.invalidArgument, message: "missing standard input")
        }
        invocation = Invocation(
            executable: executable,
            arguments: arguments,
            environment: environment,
            input: try Data(contentsOf: standardInput))
        return result
    }
}
