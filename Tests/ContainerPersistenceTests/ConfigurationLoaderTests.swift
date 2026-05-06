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
import ContainerizationExtras
import Foundation
import SystemPackage
import Testing

@testable import ContainerPersistence

struct ConfigurationLoaderTests {
    private static func writeToml(_ contents: String, to path: FilePath) throws {
        try contents.write(
            to: URL(filePath: path.string),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Lenient plugin config used by most `loadForPlugin` tests: missing `cpu`
    /// decodes to the default of 99, so tests can assert "default" vs "loaded".
    private struct TestPluginConfig: LoadablePluginConfiguration {
        static let pluginId = "foo"
        var cpu: Int
        init() { self.cpu = 99 }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.cpu = try container.decodeIfPresent(Int.self, forKey: .cpu) ?? 99
        }
    }

    /// A structurally different plugin config — strict decode of `memory`.
    /// Used by:
    /// - `loadForPluginIsolatesFromHostileSibling`: paired with a sibling
    ///   `[plugin.*]` section that also defines `memory`, so a scoping leak
    ///   would surface as a wrong value rather than a thrown error.
    /// - `loadForPluginMalformedSectionThrows`: exercises strict decode against
    ///   a malformed target section.
    private struct TestPluginConfig2: LoadablePluginConfiguration {
        static let pluginId = "mem"
        var memory: String
        init() { self.memory = "1g" }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.memory = try container.decode(String.self, forKey: .memory)
        }
    }

    /// Plugin config with an empty `pluginId` to exercise the empty-id guard.
    private struct EmptyIdPluginConfig: LoadablePluginConfiguration {
        static let pluginId = ""
        init() {}
    }

    @Test func layeredFilesPerKeyPrecedence() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let appRoot = tempDir.appending("appRoot.toml")
            let installRoot = tempDir.appending("installRoot.toml")
            try Self.writeToml("[build]\nrosetta = false\n", to: appRoot)
            try Self.writeToml("[registry]\ndomain = \"foo.bar\"\n", to: installRoot)

            let config: ContainerSystemConfig = try await ConfigurationLoader.load(
                configurationFiles: [appRoot, installRoot]
            )
            #expect(config.build.rosetta == false)
            #expect(config.registry.domain == "foo.bar")
        }
    }

    @Test func defaultsWithNoFile() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let path = tempDir.appending("nonexistent.toml")
            let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [path])
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
    }

    @Test func tomlOverrideAllKeys() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
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
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [tmpFile])
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
    }

    @Test func partialToml() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let toml = """
                [build]
                cpus = 16
                """
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [tmpFile])
            #expect(config.build.cpus == 16)
            #expect(config.build.rosetta == true)
            #expect(config.build.memory == BuildConfig.defaultMemory)
            #expect(config.container.cpus == 4)
            #expect(config.container.memory == ContainerConfig.defaultMemory)
        }
    }

    @Test func unknownKeysIgnored() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let toml = """
                [build]
                cpus = 4
                unknownBuildKey = "ignored"

                [unknownSection]
                foo = "bar"
                """
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [tmpFile])
            #expect(config.build.cpus == 4)
            #expect(config.build.rosetta == true)
        }
    }

    @Test func invalidTomlThrows() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let tmpFile = tempDir.appending("test-invalid.toml")
            try Self.writeToml("this is [not valid toml", to: tmpFile)
            await #expect(throws: (any Error).self) {
                let _: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [tmpFile])
            }
        }
    }

    @Test func emptyTomlDecodesToDefaults() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml("", to: tmpFile)

            let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [tmpFile])
            #expect(config.build.rosetta == true)
            #expect(config.build.cpus == 2)
            #expect(config.container.cpus == 4)
            #expect(config.registry.domain == "docker.io")
        }
    }

    @Test func copyConfigToAppRoot() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let source = tempDir.appending("runtime-config.toml")
            try Self.writeToml("[build]\ncpus = 8", to: source)

            let destBase = tempDir.appending("dest")
            try ConfigurationLoader.copyConfigurationToReadOnly(from: source, to: destBase)

            let destFile = destBase.appending("config").appending("runtime-config.toml")
            let copied = try String(contentsOf: URL(filePath: destFile.string), encoding: .utf8)
            #expect(copied.contains("cpus = 8"))

            let attrs = try FileManager.default.attributesOfItem(atPath: destFile.string)
            let perms = try #require(attrs[.posixPermissions] as? Int)
            #expect(perms == 0o444)
        }
    }

    @Test func copyConfigOverwritesExistingReadOnlyDestination() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let source = tempDir.appending("runtime-config.toml")
            let destBase = tempDir.appending("dest")

            try Self.writeToml("[build]\ncpus = 8", to: source)
            try ConfigurationLoader.copyConfigurationToReadOnly(from: source, to: destBase)

            try Self.writeToml("[build]\ncpus = 16", to: source)
            try ConfigurationLoader.copyConfigurationToReadOnly(from: source, to: destBase)

            let destFile = destBase.appending("config").appending("runtime-config.toml")
            let copied = try String(contentsOf: URL(filePath: destFile.string), encoding: .utf8)
            #expect(copied.contains("cpus = 16"))

            let attrs = try FileManager.default.attributesOfItem(atPath: destFile.string)
            let perms = try #require(attrs[.posixPermissions] as? Int)
            #expect(perms == 0o444)
        }
    }

    @Test func copyConfigNoOpsWhenSourceMissing() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let source = tempDir.appending("nonexistent.toml")
            let destBase = tempDir.appending("dest")
            try ConfigurationLoader.copyConfigurationToReadOnly(from: source, to: destBase)
            let destFile = destBase.appending("config").appending("runtime-config.toml")
            #expect(!FileManager.default.fileExists(atPath: destFile.string))
        }
    }

    @Test func loadForPluginDecodesQualifiedSection() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let toml = """
                [build]
                cpus = 8

                [plugin.foo]
                cpu = 4

                [plugin.other]
                unrelated = "value that would not decode as TestPluginConfig"
                """
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            let foo: TestPluginConfig = try await ConfigurationLoader.loadForPlugin(
                configurationFiles: [tmpFile])
            #expect(foo.cpu == 4)
        }
    }

    @Test func loadForPluginMissingSectionReturnsDefault() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let toml = """
                [build]
                cpus = 8
                """
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            let foo: TestPluginConfig = try await ConfigurationLoader.loadForPlugin(
                configurationFiles: [tmpFile])
            #expect(foo.cpu == 99)
        }
    }

    @Test func loadForPluginSubsectionMissingReturnsDefault() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let toml = """
                [plugin.other]
                cpu = 4
                """
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            let foo: TestPluginConfig = try await ConfigurationLoader.loadForPlugin(
                configurationFiles: [tmpFile])
            #expect(foo.cpu == 99)
        }
    }

    @Test func loadForPluginFileMissingReturnsDefault() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let missing = tempDir.appending("nonexistent.toml")
            let foo: TestPluginConfig = try await ConfigurationLoader.loadForPlugin(
                configurationFiles: [missing])
            #expect(foo.cpu == 99)
        }
    }

    @Test func loadForPluginIsolatesFromHostileSibling() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let toml = """
                [plugin.mem]
                memory = "2g"

                [plugin.other]
                memory = "999g"
                """
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            let mem: TestPluginConfig2 = try await ConfigurationLoader.loadForPlugin(
                configurationFiles: [tmpFile])
            #expect(mem.memory == "2g")
        }
    }

    @Test func loadForPluginMalformedSectionThrows() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let toml = """
                [plugin.mem]
                memory = 42
                """
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml(toml, to: tmpFile)

            await #expect(throws: (any Error).self) {
                let _: TestPluginConfig2 = try await ConfigurationLoader.loadForPlugin(
                    configurationFiles: [tmpFile])
            }
        }
    }

    @Test func loadForPluginEmptyIdThrows() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let tmpFile = tempDir.appending("test.toml")
            try Self.writeToml("[plugin.foo]\ncpu = 4", to: tmpFile)

            await #expect(throws: (any Error).self) {
                let _: EmptyIdPluginConfig = try await ConfigurationLoader.loadForPlugin(
                    configurationFiles: [tmpFile])
            }
        }
    }

    @Test func layeredPrecedence() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let userFile = tempDir.appending("user.toml")
            let systemFile = tempDir.appending("system.toml")

            try Self.writeToml(
                """
                [build]
                cpus = 8
                """, to: userFile)

            try Self.writeToml(
                """
                [build]
                cpus = 4
                memory = "4096MB"
                """, to: systemFile)

            let config: ContainerSystemConfig = try await ConfigurationLoader.load(
                configurationFiles: [userFile, systemFile]
            )
            #expect(config.build.cpus == 8)
            let expectedMemory = try MemorySize("4096MB")
            #expect(config.build.memory == expectedMemory)
        }
    }

    @Test func allFilesMissingReturnsDefaults() async throws {
        let config: ContainerSystemConfig = try await ConfigurationLoader.load(
            configurationFiles: [FilePath("/nonexistent/a.toml"), FilePath("/nonexistent/b.toml")]
        )
        #expect(config.build.rosetta == true)
        #expect(config.build.cpus == 2)
    }

    @Test func partialOverlapMergesKeys() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let userFile = tempDir.appending("user.toml")
            let systemFile = tempDir.appending("system.toml")

            try Self.writeToml(
                """
                [dns]
                domain = "user.local"
                """, to: userFile)

            try Self.writeToml(
                """
                [build]
                cpus = 16
                """, to: systemFile)

            let config: ContainerSystemConfig = try await ConfigurationLoader.load(
                configurationFiles: [userFile, systemFile]
            )
            #expect(config.dns.domain == "user.local")
            #expect(config.build.cpus == 16)
        }
    }

    @Test func pluginLayering() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let userFile = tempDir.appending("user.toml")
            let systemFile = tempDir.appending("system.toml")

            try Self.writeToml(
                """
                [plugin.foo]
                cpu = 8
                """, to: userFile)

            try Self.writeToml(
                """
                [plugin.foo]
                cpu = 2
                """, to: systemFile)

            let config: TestPluginConfig = try await ConfigurationLoader.loadForPlugin(
                configurationFiles: [userFile, systemFile]
            )
            #expect(config.cpu == 8)
        }
    }

    @Test func loadErrorIdentifiesMalformedLayerFile() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let userFile = tempDir.appending("user.toml")
            let systemFile = tempDir.appending("system.toml")

            try Self.writeToml("[build]\ncpus = 8", to: userFile)
            try Self.writeToml("this is [not valid toml", to: systemFile)

            let error = try #require(
                await #expect(throws: (any Error).self) {
                    let _: ContainerSystemConfig = try await ConfigurationLoader.load(
                        configurationFiles: [userFile, systemFile])
                }
            )
            #expect(String(describing: error).contains(systemFile.string))
        }
    }

    @Test func loadForPluginErrorIdentifiesMalformedLayerFile() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let userFile = tempDir.appending("user.toml")
            let systemFile = tempDir.appending("system.toml")

            try Self.writeToml("this is [not valid toml", to: userFile)
            try Self.writeToml("[plugin.foo]\ncpu = 2", to: systemFile)

            let error = try #require(
                await #expect(throws: (any Error).self) {
                    let _: TestPluginConfig = try await ConfigurationLoader.loadForPlugin(
                        configurationFiles: [userFile, systemFile])
                }
            )
            #expect(String(describing: error).contains(userFile.string))
        }
    }
}
