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

import ContainerResource
import ContainerRuntimeClient
import ContainerRuntimeLinuxClient
import Containerization
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

        let linuxData = LinuxRuntimeData(
            kernelPath: "/path/to/kernel",
            initImageRef: "init:latest",
            imageRef: "alpine:latest"
        )
        let encodedData = try JSONEncoder().encode(linuxData)

        let runtimeConfig = RuntimeConfiguration(
            path: bundlePath,
            runtimeData: encodedData
        )

        try runtimeConfig.writeRuntimeConfiguration()
        let readConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)

        #expect(readConfig.path == bundlePath)
        #expect(readConfig.runtimeData != nil)
        #expect(readConfig.containerConfiguration == nil)
        #expect(readConfig.options == nil)
        #expect(readConfig.kernel == nil)
        #expect(readConfig.initialFilesystem == nil)
    }

    @Test
    func testRuntimeConfigurationWithVariant() throws {
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

        let linuxData = LinuxRuntimeData(
            variant: "test-variant",
            kernelPath: "/path/to/kernel",
            initImageRef: "init:latest",
            imageRef: "ubuntu:22.04"
        )
        let encodedData = try JSONEncoder().encode(linuxData)

        let runtimeConfig = RuntimeConfiguration(
            path: bundlePath,
            runtimeData: encodedData,
            initialFilesystem: initFs,
            kernel: kernel
        )

        try runtimeConfig.writeRuntimeConfiguration()

        let readRuntimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)

        #expect(readRuntimeConfig.runtimeData != nil, "runtimeData should be persisted")

        let decodedData = try JSONDecoder().decode(LinuxRuntimeData.self, from: readRuntimeConfig.runtimeData!)
        #expect(decodedData.variant == "test-variant", "Variant should round-trip through RuntimeConfiguration")
    }

    /// Test that LinuxRuntimeData encodes and decodes correctly with all fields populated.
    @Test
    func testLinuxRuntimeDataFullEncoding() throws {
        let original = LinuxRuntimeData(
            variant: "rosetta",
            kernelPath: "/usr/local/share/container/kernel",
            initImageRef: "ghcr.io/apple/container-init:latest",
            imageRef: "ubuntu:22.04"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: encoded)

        #expect(decoded.variant == original.variant, "variant should round-trip")
        #expect(decoded.kernelPath == original.kernelPath, "kernelPath should round-trip")
        #expect(decoded.initImageRef == original.initImageRef, "initImageRef should round-trip")
        #expect(decoded.imageRef == original.imageRef, "imageRef should round-trip")
    }

    /// Test that LinuxRuntimeData encodes and decodes correctly when optional fields are nil.
    @Test
    func testLinuxRuntimeDataNilContainerImageRef() throws {
        let original = LinuxRuntimeData(
            variant: nil,
            kernelPath: "/usr/local/share/container/kernel",
            initImageRef: "ghcr.io/apple/container-init:latest",
            imageRef: nil
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: encoded)

        #expect(decoded.variant == nil, "variant should be nil")
        #expect(decoded.kernelPath == original.kernelPath, "kernelPath should round-trip")
        #expect(decoded.initImageRef == original.initImageRef, "initImageRef should round-trip")
        #expect(decoded.imageRef == nil, "imageRef should be nil")
    }

    /// Test that a new-format RuntimeConfiguration (runtimeData only, no legacy fields) round-trips correctly.
    @Test
    func testNewFormatRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-new-format-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let linuxData = LinuxRuntimeData(
            variant: "default",
            kernelPath: "/path/to/kernel",
            initImageRef: "init:latest",
            imageRef: "alpine:3.20"
        )
        let runtimeData = try JSONEncoder().encode(linuxData)

        let config = RuntimeConfiguration(
            path: bundlePath,
            containerConfiguration: nil,
            options: nil,
            runtimeData: runtimeData
        )

        try config.writeRuntimeConfiguration()
        let read = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)

        #expect(read.runtimeData != nil)
        #expect(read.kernel == nil, "New format should not have legacy kernel field")
        #expect(read.initialFilesystem == nil, "New format should not have legacy filesystem field")

        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: read.runtimeData!)
        #expect(decoded.kernelPath == "/path/to/kernel")
        #expect(decoded.initImageRef == "init:latest")
        #expect(decoded.imageRef == "alpine:3.20")
        #expect(decoded.variant == "default")
    }

    /// Test the rootFsOverride case where imageRef is nil.
    @Test
    func testNewFormatWithNilContainerImageRef() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-nil-ref-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let linuxData = LinuxRuntimeData(
            kernelPath: "/path/to/kernel",
            initImageRef: "init:latest",
            imageRef: nil
        )
        let runtimeData = try JSONEncoder().encode(linuxData)

        let config = RuntimeConfiguration(
            path: bundlePath,
            runtimeData: runtimeData
        )

        try config.writeRuntimeConfiguration()
        let read = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)

        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: read.runtimeData!)
        #expect(decoded.imageRef == nil)
        #expect(decoded.initImageRef == "init:latest")
    }
}
