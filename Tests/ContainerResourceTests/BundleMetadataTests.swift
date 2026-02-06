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

import ContainerAPIService
import ContainerResource
import Containerization
import ContainerizationOCI
import Foundation
import Testing

/// Unit tests for Bundle metadata functionality.
///
/// These tests verify the Bundle metadata serialization and deserialization,
/// ensuring that metadata can be properly written, read, and used to create bundles.
struct BundleMetadataTests {

    /// Test that reading non-existent metadata file throws appropriate error
    @Test
    func testReadNonExistentMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let nonExistentPath = tempDir.appendingPathComponent("non-existent-\(UUID()).json")

        #expect(throws: Error.self) {
            _ = try ContainerResource.Bundle.readMetadata(from: nonExistentPath)
        }
    }

    /// Test that metadata reads and writes as expected
    @Test
    func testMetadataReadWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-bundle-\(UUID())")
        let metadataPath = tempDir.appendingPathComponent("test-metadata-\(UUID()).json")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
            try? FileManager.default.removeItem(at: metadataPath)
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

        let metadata = BundleMetadata(
            path: bundlePath,
            initialFilesystem: initFs,
            kernel: kernel,
            containerConfiguration: nil,
            containerRootFilesystem: nil,
            options: nil
        )

        try ContainerResource.Bundle.writeMetadata(metadata, to: metadataPath)
        let readMetadata = try ContainerResource.Bundle.readMetadata(from: metadataPath)

        #expect(
            readMetadata.path == bundlePath,
            "Path should match")
        #expect(
            readMetadata.kernel.path == kernel.path,
            "Kernel path should match")
        #expect(
            readMetadata.initialFilesystem.source == initFs.source,
            "Initial filesystem source should match")
        #expect(
            readMetadata.containerConfiguration == nil,
            "Container configuration should be nil")
        #expect(
            readMetadata.containerRootFilesystem == nil,
            "Root filesystem should be nil")
        #expect(
            readMetadata.options == nil,
            "Options should be nil")
    }
}
