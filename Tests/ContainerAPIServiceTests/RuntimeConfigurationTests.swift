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

/// Unit tests for RuntimeConfiguration and LinuxRuntimeData serialization,
/// covering the round-trip of the configuration format and the decoding of
/// legacy-format configurations the runtime still boots from directly.
struct RuntimeConfigurationTests {

    /// Reading a non-existent runtime configuration file throws.
    @Test
    func testReadNonExistentRuntimeConfiguration() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let nonExistentPath = tempDir.appendingPathComponent("non-existent-\(UUID()).json")

        #expect(throws: Error.self) {
            _ = try RuntimeConfiguration.readRuntimeConfiguration(from: nonExistentPath)
        }
    }

    /// A RuntimeConfiguration reads, writes, and round-trips through disk.
    @Test
    func testRuntimeConfigurationReadWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-bundle-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let runtimeData = try LinuxRuntimeData.encodeData(
            kernelPath: "/path/to/kernel",
            initImageRef: "init:latest"
        )

        let runtimeConfig = RuntimeConfiguration(path: bundlePath, runtimeData: runtimeData)
        try runtimeConfig.writeRuntimeConfiguration()

        let readConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)
        #expect(readConfig.path == bundlePath)
        #expect(readConfig.runtimeData != nil)
        #expect(readConfig.containerConfiguration == nil)
        #expect(readConfig.options == nil)
        // A freshly-written configuration carries no legacy fields.
        #expect(readConfig.kernel == nil)
        #expect(readConfig.initialFilesystem == nil)
    }

    /// The variant round-trips through RuntimeConfiguration's runtimeData blob.
    @Test
    func testRuntimeConfigurationWithVariant() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-bundle-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let runtimeData = try LinuxRuntimeData.encodeData(
            kernelPath: "/path/to/kernel",
            initImageRef: "init:latest",
            variant: "test-variant"
        )

        let runtimeConfig = RuntimeConfiguration(path: bundlePath, runtimeData: runtimeData)
        try runtimeConfig.writeRuntimeConfiguration()

        let readConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)
        #expect(readConfig.runtimeData != nil, "runtimeData should be persisted")

        let decoded = try LinuxRuntimeData.decodeData(readConfig.runtimeData!)
        #expect(decoded.variant == "test-variant", "variant should round-trip")
    }

    /// LinuxRuntimeData round-trips through Codable.
    @Test
    func testLinuxRuntimeDataReferenceRoundTrip() throws {
        let original = LinuxRuntimeData(
            variant: "rosetta",
            kernelPath: "/usr/local/share/container/kernel",
            initImageRef: "ghcr.io/apple/container-init:latest"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: encoded)

        #expect(decoded.variant == "rosetta")
        #expect(decoded.kernelPath == "/usr/local/share/container/kernel")
        #expect(decoded.initImageRef == "ghcr.io/apple/container-init:latest")
    }

    /// A RuntimeConfiguration with runtimeData round-trips end to end through disk.
    @Test
    func testRuntimeConfigurationRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-roundtrip-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let runtimeData = try LinuxRuntimeData.encodeData(
            kernelPath: "/path/to/kernel",
            initImageRef: "init:latest",
            variant: "default"
        )

        let config = RuntimeConfiguration(path: bundlePath, runtimeData: runtimeData)
        try config.writeRuntimeConfiguration()

        let read = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)
        #expect(read.runtimeData != nil)
        #expect(read.kernel == nil)
        #expect(read.initialFilesystem == nil)

        let decoded = try LinuxRuntimeData.decodeData(read.runtimeData!)
        #expect(decoded.kernelPath == "/path/to/kernel")
        #expect(decoded.variant == "default")
        #expect(decoded.initImageRef == "init:latest")
    }

    /// A legacy-format configuration (legacy kernel/filesystem fields, no runtimeData) is
    /// decodable, with legacy fields populated. The runtime boots directly from these fields.
    ///
    /// TODO: remove after migration period
    @Test
    func testLegacyConfigurationDecodes() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-legacy-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)

        // Produce accurate legacy-format JSON from real Kernel/Filesystem values, matching
        // what a pre-conversion version wrote to disk.
        let kernel = Kernel(path: URL(fileURLWithPath: "/usr/local/lib/container/kernel"), platform: .linuxArm)
        let initFs = Filesystem.virtiofs(source: "/var/lib/container/snapshots/init123/snapshot", destination: "/", options: ["ro"])
        let legacy = LegacyRuntimeConfiguration(
            path: bundlePath,
            kernel: kernel,
            initialFilesystem: initFs
        )
        let configPath = bundlePath.appendingPathComponent("runtime-configuration.json")
        try JSONEncoder().encode(legacy).write(to: configPath)

        let config = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)
        #expect(config.runtimeData == nil)
        #expect(config.kernel?.path.path == "/usr/local/lib/container/kernel")
        #expect(config.initialFilesystem?.source == "/var/lib/container/snapshots/init123/snapshot")
    }
}

/// Mirror of the legacy RuntimeConfiguration on-disk format, used by tests to produce
/// accurate legacy-format JSON via the real Kernel/Filesystem Codable conformances.
/// TODO: remove after migration period
private struct LegacyRuntimeConfiguration: Codable {
    let path: URL
    let kernel: Kernel
    let initialFilesystem: Filesystem
}
