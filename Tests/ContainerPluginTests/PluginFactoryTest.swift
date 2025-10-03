//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import Foundation
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

        // write config to {name}/config.json
        let configURL = tempURL.appending(path: "config.json")
        let configJson = """
            {
                "abstract" : "Default network management service",
                "author": "Apple"
            }
            """
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryDirURL = tempURL.appending(path: "bin")
        try fm.createDirectory(at: binaryDirURL, withIntermediateDirectories: true)
        let binaryURL = binaryDirURL.appending(path: name)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory()
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

        // write config to {name}/config.json
        let configURL = tempURL.appending(path: "config.json")
        let configJson = """
            {
                "abstract" : "Default network management service",
                "author": "Apple"
            }
            """
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryDirURL = tempURL.appending(path: "bin")
        try fm.createDirectory(at: binaryDirURL, withIntermediateDirectories: true)
        let binaryURL = binaryDirURL.appending(path: name)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory()
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

        let factory = DefaultPluginFactory()
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

        // write config to {name}/config.json
        let configURL = tempURL.appending(path: "config.json")
        let configJson = """
            {
                "abstract" : "Default network management service",
                "author": "Apple"
            }
            """
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)

        let factory = DefaultPluginFactory()
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

        // write config to {name}/config.json
        let configURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "Resources")
            .appending(path: "config.json")
        let configJson = """
            {
                "abstract" : "Default network management service",
                "author": "Apple"
            }
            """
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "MacOS")
            .appending(path: name)
        try fm.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = AppBundlePluginFactory()
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

        // write config to {name}/config.json
        let configURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "Resources")
            .appending(path: "config.json")
        let configJson = """
            {
                "abstract" : "Default network management service",
                "author": "Apple"
            }
            """
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try configJson.write(to: configURL, atomically: true, encoding: .utf8)

        // write binary to {name}/bin/{name}
        let binaryURL =
            installURL
            .appending(path: "Contents")
            .appending(path: "MacOS")
            .appending(path: name)
        try fm.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: binaryURL, atomically: true, encoding: .utf8)

        let factory = AppBundlePluginFactory()
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
}
