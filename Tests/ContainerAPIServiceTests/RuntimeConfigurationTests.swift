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

// import ContainerAPIService
import ContainerResource
import ContainerSandboxServiceClient
import Containerization
// import ContainerizationOCI
import Foundation
import Testing

/// Unit tests for RuntimeConfiguration functionality.
///
/// These tests verify the runtime configuration serialization and deserialization,
/// ensuring that configuration can be properly written, read, and used to create bundles.
struct RuntimeConfigurationTests {

    /// Test that reading non-existent runtime configuration file throws
    /// appropriate error
    @Test
    func testReadNonExistentRuntimeConfiguration() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let nonExistentPath = tempDir.appendingPathComponent("non-existent-\(UUID()).json")

        #expect(throws: Error.self) {
            _ = try RuntimeConfiguration.readRuntimeConfiguration(from: nonExistentPath)
        }
    }

    /// Test that runtime configuration reads and writes as expected
    @Test
    func testRuntimeConfigurationReadWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-bundle-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let initFs = Filesystem.virtiofs(
            source: "/path/to/initfs",
            destination: "/",
            options: ["ro"]
        )

        let kernel = Kernel(
            path: URL(fileURLWithPath: "/path/to/kernel"),
            platform: .linuxArm
        )

        let runtimeConfig = RuntimeConfiguration(
            path: bundlePath,
            initialFilesystem: initFs,
            kernel: kernel,
            containerConfiguration: nil,
            containerRootFilesystem: nil,
            options: nil
        )

        try runtimeConfig.writeRuntimeConfiguration()

        defer {
            try? FileManager.default.removeItem(at: runtimeConfig.runtimeConfigurationPath)
        }

        let readRuntimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)

        #expect(
            readRuntimeConfig.path == bundlePath,
            "Path should match")
        #expect(
            readRuntimeConfig.kernel.path == kernel.path,
            "Kernel path should match")
        #expect(
            readRuntimeConfig.initialFilesystem.source == initFs.source,
            "Initial filesystem source should match")
        #expect(
            readRuntimeConfig.containerConfiguration == nil,
            "Container configuration should be nil")
        #expect(
            readRuntimeConfig.containerRootFilesystem == nil,
            "Root filesystem should be nil")
        #expect(
            readRuntimeConfig.options == nil,
            "Options should be nil")
    }
}
