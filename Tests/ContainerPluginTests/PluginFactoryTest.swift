//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

@testable import ContainerPlugin

struct PluginFactoryTest {
    @Test
    func testDefaultFactory() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let name = tempURL.lastPathComponent

        // write config to {name}/config.toml
        let configURL = tempURL.appending(path: "config.toml")
        let configToml = """
            abstract = "Default network management service"
            author = "Apple"
            """
        try configToml.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryDirURL = tempURL.appending(path: "bin")
        try fm.createDirectory(at: binaryDirURL, withIntermediateDirectories: true)
        let binaryURL = binaryDirURL.appending(path: name)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        let plugin = try #require(try factory.create(installURL: tempURL))

        #expect(plugin.name == name)
        #expect(!plugin.shouldBoot)
        #expect(plugin.getLaunchdLabel() == "com.apple.container.\(name)")
        #expect(plugin.getLaunchdLabel(instanceId: "1") == "com.apple.container.\(name).1")
        #expect(plugin.getMachServices() == [])
        #expect(plugin.getMachServices(instanceId: "1") == [])
        #expect(plugin.getMachService(type: .runtime) == nil)
        #expect(plugin.getMachService(instanceId: "1", type: .runtime) == nil)
        #expect(!plugin.hasType(.runtime))
        #expect(!plugin.hasType(.network))
        #expect(plugin.helpText(padding: 40).hasSuffix("Default network management service"))
    }

    @Test
    func testDefaultFactoryByName() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let name = tempURL.lastPathComponent

        // write config to {name}/config.toml
        let configURL = tempURL.appending(path: "config.toml")
        let configToml = """
            abstract = "Default network management service"
            author = "Apple"
            """
        try configToml.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryDirURL = tempURL.appending(path: "bin")
        try fm.createDirectory(at: binaryDirURL, withIntermediateDirectories: true)
        let binaryURL = binaryDirURL.appending(path: name)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        let plugin = try #require(try factory.create(parentURL: tempURL.deletingLastPathComponent(), name: name))

        #expect(plugin.name == name)
        #expect(!plugin.shouldBoot)
        #expect(plugin.getLaunchdLabel() == "com.apple.container.\(name)")
        #expect(plugin.getLaunchdLabel(instanceId: "1") == "com.apple.container.\(name).1")
        #expect(plugin.getMachServices() == [])
        #expect(plugin.getMachServices(instanceId: "1") == [])
        #expect(plugin.getMachService(type: .runtime) == nil)
        #expect(plugin.getMachService(instanceId: "1", type: .runtime) == nil)
        #expect(!plugin.hasType(.runtime))
        #expect(!plugin.hasType(.network))
        #expect(plugin.helpText(padding: 40).hasSuffix("Default network management service"))
    }

    @Test
    func testDefaultFactoryMissingConfig() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let name = tempURL.lastPathComponent

        // write binary to {name}/bin/{name}
        let binaryDirURL = tempURL.appending(path: "bin")
        try fm.createDirectory(at: binaryDirURL, withIntermediateDirectories: true)
        let binaryURL = binaryDirURL.appending(path: name)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        let plugin = try factory.create(installURL: tempURL)
        #expect(plugin == nil)
    }

    @Test
    func testDefaultFactoryMissingBinary() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // write config to {name}/config.toml
        let configURL = tempURL.appending(path: "config.toml")
        let configToml = """
            abstract = "Default network management service"
            author = "Apple"
            """
        try configToml.write(to: configURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        let plugin = try factory.create(installURL: tempURL)
        #expect(plugin == nil)
    }

    @Test
    func testAppBundleFactory() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let installURL = tempURL.appending(path: "test.app")
        try fm.createDirectory(at: installURL, withIntermediateDirectories: true)
        let name = String(installURL.lastPathComponent.dropLast(4))

        // write config to {name}/config.toml
        let configURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "Resources")
            .appending(path: "config.toml")
        let configToml = """
            abstract = "Default network management service"
            author = "Apple"
            """
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configToml.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "MacOS")
            .appending(path: name)
        try fm.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = AppBundlePluginFactory(logger: Logger(label: "test"))
        let plugin = try #require(try factory.create(installURL: installURL))

        #expect(plugin.name == name)
        #expect(!plugin.shouldBoot)
        #expect(plugin.getLaunchdLabel() == "com.apple.container.\(name)")
        #expect(plugin.getLaunchdLabel(instanceId: "1") == "com.apple.container.\(name).1")
        #expect(plugin.getMachServices() == [])
        #expect(plugin.getMachServices(instanceId: "1") == [])
        #expect(plugin.getMachService(type: .runtime) == nil)
        #expect(plugin.getMachService(instanceId: "1", type: .runtime) == nil)
        #expect(!plugin.hasType(.runtime))
        #expect(!plugin.hasType(.network))
        #expect(plugin.helpText(padding: 40).hasSuffix("Default network management service"))
    }

    @Test
    func testAppBundleFactoryByName() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let installURL = tempURL.appending(path: "test.app")
        try fm.createDirectory(at: installURL, withIntermediateDirectories: true)
        let name = String(installURL.lastPathComponent.dropLast(4))

        // write config to {name}/config.toml
        let configURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "Resources")
            .appending(path: "config.toml")
        let configToml = """
            abstract = "Default network management service"
            author = "Apple"
            """
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configToml.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "MacOS")
            .appending(path: name)
        try fm.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = AppBundlePluginFactory(logger: Logger(label: "test"))
        let plugin = try #require(try factory.create(parentURL: tempURL, name: name))

        #expect(plugin.name == name)
        #expect(!plugin.shouldBoot)
        #expect(plugin.getLaunchdLabel() == "com.apple.container.\(name)")
        #expect(plugin.getLaunchdLabel(instanceId: "1") == "com.apple.container.\(name).1")
        #expect(plugin.getMachServices() == [])
        #expect(plugin.getMachServices(instanceId: "1") == [])
        #expect(plugin.getMachService(type: .runtime) == nil)
        #expect(plugin.getMachService(instanceId: "1", type: .runtime) == nil)
        #expect(!plugin.hasType(.runtime))
        #expect(!plugin.hasType(.network))
        #expect(plugin.helpText(padding: 40).hasSuffix("Default network management service"))
    }

    @Test
    func testDefaultFactoryFallsBackToJson() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let name = tempURL.lastPathComponent

        // write config to {name}/config.json (no config.toml)
        let configURL = tempURL.appending(path: "config.json")
        let configJson = """
            {"abstract": "JSON fallback service", "author": "Apple"}
            """
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryDirURL = tempURL.appending(path: "bin")
        try fm.createDirectory(at: binaryDirURL, withIntermediateDirectories: true)
        let binaryURL = binaryDirURL.appending(path: name)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        let plugin = try #require(try factory.create(installURL: tempURL))

        #expect(plugin.name == name)
        #expect(plugin.config.abstract == "JSON fallback service")
        #expect(plugin.config.author == "Apple")
    }

    @Test
    func testDefaultFactoryPrefersTomlOverJson() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let name = tempURL.lastPathComponent

        // write config.toml
        let tomlURL = tempURL.appending(path: "config.toml")
        let configToml = """
            abstract = "TOML service"
            author = "Apple"
            """
        try configToml.write(to: tomlURL, atomically: true, encoding: .utf8)

        // write config.json with a different abstract
        let jsonURL = tempURL.appending(path: "config.json")
        let configJson = """
            {"abstract": "JSON service", "author": "Apple"}
            """
        try configJson.write(to: jsonURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryDirURL = tempURL.appending(path: "bin")
        try fm.createDirectory(at: binaryDirURL, withIntermediateDirectories: true)
        let binaryURL = binaryDirURL.appending(path: name)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        let plugin = try #require(try factory.create(installURL: tempURL))

        #expect(plugin.name == name)
        #expect(plugin.config.abstract == "TOML service")
    }

    @Test
    func testDefaultFactoryRejectsTraversalName() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // A complete, loadable plugin layout planted outside the plugin parent directory.
        let outsideURL = tempURL.appending(path: "outside")
        let binDirURL = outsideURL.appending(path: "bin")
        try fm.createDirectory(at: binDirURL, withIntermediateDirectories: true)
        try "abstract = \"payload\"\nauthor = \"Apple\""
            .write(to: outsideURL.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        try "".write(to: binDirURL.appending(path: "outside"), atomically: true, encoding: .utf8)

        let pluginParent = tempURL.appending(path: "plugins")
        try fm.createDirectory(at: pluginParent, withIntermediateDirectories: true)

        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        #expect(throws: ContainerizationError.self) {
            try factory.create(parentURL: pluginParent, name: "../outside")
        }
    }

    @Test
    func testDefaultFactoryRejectsParentDirectoryName() async throws {
        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        #expect(throws: ContainerizationError.self) {
            try factory.create(parentURL: URL(fileURLWithPath: "/tmp"), name: "..")
        }
    }

    @Test
    func testDefaultFactoryRejectsNullByteTraversalName() async throws {
        let factory = DefaultPluginFactory(logger: Logger(label: "test"))
        #expect(throws: ContainerizationError.self) {
            try factory.create(parentURL: URL(fileURLWithPath: "/tmp"), name: "evil\u{0}/../../../../etc")
        }
    }

    @Test
    func testAppBundleFactoryRejectsTraversalName() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // A complete, loadable app-bundle plugin layout planted outside the plugin parent directory.
        let outsideURL = tempURL.appending(path: "outside.app")
        let resourcesURL = outsideURL.appending(path: "Contents").appending(path: "Resources")
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try "abstract = \"payload\"\nauthor = \"Apple\""
            .write(to: resourcesURL.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        let macosURL = outsideURL.appending(path: "Contents").appending(path: "MacOS")
        try fm.createDirectory(at: macosURL, withIntermediateDirectories: true)
        try "".write(to: macosURL.appending(path: "outside"), atomically: true, encoding: .utf8)

        let pluginParent = tempURL.appending(path: "plugins")
        try fm.createDirectory(at: pluginParent, withIntermediateDirectories: true)

        let factory = AppBundlePluginFactory(logger: Logger(label: "test"))
        #expect(throws: ContainerizationError.self) {
            try factory.create(parentURL: pluginParent, name: "../outside")
        }
    }
}
