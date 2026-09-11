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

// MARK: - K8sHelper.loadCNIManifest

@Suite("K8sHelper.loadCNIManifest")
struct LoadCNIManifestTests {
    private let log = Logger(label: "test")

    @Test func customPathReturnsItsContents() async throws {
        let contents = "kind: DaemonSet\nmetadata:\n  name: my-custom-cni\n"
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(UUID().uuidString + ".yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await K8sHelper.loadCNIManifest(path: url.path, log: log)
        #expect(result == contents)
    }

    @Test func missingPathThrowsInvalidArgument() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-does-not-exist.yaml").path

        await #expect(throws: ContainerizationError.self) {
            _ = try await K8sHelper.loadCNIManifest(path: missingPath, log: log)
        }
    }

    @Test func customPathTakesPrecedenceOverBundledCNI() async throws {
        // A non-nil path must never fall through to the bundled kindnet
        // lookup, which requires a real plugin installation and would fail
        // in a unit test environment.
        let contents = "custom-cni-marker"
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(UUID().uuidString + ".yaml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await K8sHelper.loadCNIManifest(path: url.path, log: log)
        #expect(result == contents)
        #expect(!result.contains("kindnet"))
    }
}
