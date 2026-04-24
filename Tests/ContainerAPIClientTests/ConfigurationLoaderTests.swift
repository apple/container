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

import ContainerizationExtras
import Foundation
import SystemPackage
import Testing

@testable import ContainerPersistence

struct ConfigurationLoaderTests {
    @Test func testDefaultsWithNoFile() throws {
        let path = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("nonexistent-\(UUID().uuidString).toml")
                .path(percentEncoded: false)
        )
        let config: ContainerSystemConfig = try ConfigurationLoader.load(configFile: path)
        #expect(config.build.rosetta == true)
        #expect(config.build.cpus == 2)
        #expect(config.build.memory == BuildConfig.defaultMemory)
        #expect(config.container.cpus == 4)
        #expect(config.container.memory == ContainerConfig.defaultMemory)
        #expect(config.dns.domain == nil)
        #expect(!config.build.image.isEmpty)
        #expect(!config.vminit.image.isEmpty)
        #expect(!config.kernel.binaryPath.isEmpty)
        #expect(!config.kernel.url.absoluteString.isEmpty)
        #expect(config.network.subnet == nil)
        #expect(config.network.subnetv6 == nil)
        #expect(config.registry.domain == "docker.io")
    }

    @Test func testTomlOverrideAllKeys() throws {
        let toml = """
            [build]
            rosetta = false
            cpus = 8
            memory = "4096MB"
            image = "custom-builder:latest"

            [container]
            cpus = 16
            memory = "8g"

            [dns]
            domain = "custom"

            [kernel]
            binaryPath = "custom/path"
            url = "https://example.com/kernel.tar"

            [network]
            subnet = "10.0.0.1/16"
            subnetv6 = "fd01::/48"

            [registry]
            domain = "ghcr.io"

            [vminit]
            image = "custom-init:latest"
            """
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).toml")
        try toml.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let config: ContainerSystemConfig = try ConfigurationLoader.load(
            configFile: FilePath(tmpFile.path(percentEncoded: false))
        )
        #expect(config.build.rosetta == false)
        #expect(config.build.cpus == 8)
        let expectedBuildMemory = try MemorySize("4096MB")
        #expect(config.build.memory == expectedBuildMemory)
        #expect(config.container.cpus == 16)
        let expectedContainerMemory = try MemorySize("8g")
        #expect(config.container.memory == expectedContainerMemory)
        #expect(config.dns.domain == "custom")
        #expect(config.build.image == "custom-builder:latest")
        #expect(config.vminit.image == "custom-init:latest")
        #expect(config.kernel.binaryPath == "custom/path")
        #expect(config.kernel.url.absoluteString == "https://example.com/kernel.tar")
        let expectedSubnet = try CIDRv4("10.0.0.1/16")
        let expectedSubnetV6 = try CIDRv6("fd01::/48")
        #expect(config.network.subnet == expectedSubnet)
        #expect(config.network.subnetv6 == expectedSubnetV6)
        #expect(config.registry.domain == "ghcr.io")
    }

    @Test func testPartialToml() throws {
        let toml = """
            [build]
            cpus = 16
            """
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).toml")
        try toml.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let config: ContainerSystemConfig = try ConfigurationLoader.load(
            configFile: FilePath(tmpFile.path(percentEncoded: false))
        )
        #expect(config.build.cpus == 16)
        #expect(config.build.rosetta == true)
        #expect(config.build.memory == BuildConfig.defaultMemory)
        #expect(config.container.cpus == 4)
        #expect(config.container.memory == ContainerConfig.defaultMemory)
    }

    @Test func testUnknownKeysIgnored() throws {
        let toml = """
            [build]
            cpus = 4
            unknownBuildKey = "ignored"

            [unknownSection]
            foo = "bar"
            """
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).toml")
        try toml.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let config: ContainerSystemConfig = try ConfigurationLoader.load(
            configFile: FilePath(tmpFile.path(percentEncoded: false))
        )
        #expect(config.build.cpus == 4)
        #expect(config.build.rosetta == true)
    }

    @Test func testInvalidTomlThrows() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-invalid-toml.toml")
        try "this is [not valid toml".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        #expect(throws: (any Error).self) {
            let _: ContainerSystemConfig = try ConfigurationLoader.load(
                configFile: FilePath(tmpFile.path(percentEncoded: false))
            )
        }
    }

    @Test func testEmptyTomlDecodesToDefaults() throws {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).toml")
        try "".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let config: ContainerSystemConfig = try ConfigurationLoader.load(
            configFile: FilePath(tmpFile.path(percentEncoded: false))
        )
        #expect(config.build.rosetta == true)
        #expect(config.build.cpus == 2)
        #expect(config.container.cpus == 4)
        #expect(config.registry.domain == "docker.io")
    }

    @Test func testCopyConfigToAppRoot() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        defer { try? FileManager.default.removeItem(at: destDir) }

        let sourceFile = sourceDir.appendingPathComponent("runtime-config.toml")
        try "[build]\ncpus = 8".write(to: sourceFile, atomically: true, encoding: .utf8)

        let source = FilePath(sourceFile.path(percentEncoded: false))
        let dest = FilePath(destDir.path(percentEncoded: false))
            .appending("config")
            .appending("runtime-config.toml")

        try ConfigurationLoader.copyConfigToAppRoot(from: source, to: dest)

        let copied = try String(contentsOf: URL(filePath: dest.string), encoding: .utf8)
        #expect(copied.contains("cpus = 8"))

        let attrs = try FileManager.default.attributesOfItem(atPath: dest.string)
        let perms = attrs[.posixPermissions] as! Int
        #expect(perms == 0o444)
    }

    @Test func testCopyConfigNoOpsWhenSourceMissing() throws {
        let source = FilePath("/nonexistent-\(UUID().uuidString)/runtime-config.toml")
        let dest = FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("dest-\(UUID().uuidString)")
                .appendingPathComponent("config")
                .appendingPathComponent("runtime-config.toml")
                .path(percentEncoded: false)
        )
        try ConfigurationLoader.copyConfigToAppRoot(from: source, to: dest)
        #expect(!FileManager.default.fileExists(atPath: dest.string))
    }

    @Test func testIndependentPluginConfig() throws {
        struct PluginConfig: Codable, Sendable, Initable {
            var network: NetworkConfig
            init() { self.network = .init() }
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.network = try container.decodeIfPresent(NetworkConfig.self, forKey: .network) ?? .init()
            }
        }

        let toml = """
            [build]
            cpus = 8

            [network]
            subnet = "10.1.2.3/24"
            subnetv6 = "fd02::/48"
            """
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).toml")
        try toml.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let config: PluginConfig = try ConfigurationLoader.load(
            configFile: FilePath(tmpFile.path(percentEncoded: false))
        )
        let expectedSubnet = try CIDRv4("10.1.2.3/24")
        let expectedSubnetV6 = try CIDRv6("fd02::/48")
        #expect(config.network.subnet == expectedSubnet)
        #expect(config.network.subnetv6 == expectedSubnetV6)
    }
}
