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

import Foundation
import Testing

@testable import ContainerPlugin

struct PluginLoaderTest {
    @Test
    func testFindAll() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let factory = try setupMock(tempURL: tempURL)
        let loader = try PluginLoader(
            appRoot: tempURL,
            installRoot: URL(filePath: "/usr/local/"),
            logRoot: nil,
            pluginDirectories: [tempURL],
            pluginFactories: [factory]
        )
        let plugins = loader.findPlugins()

        #expect(Set(plugins.map { $0.name }) == Set(["cli", "service"]))
    }

    @Test
    func testFindAllSymlink() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let factory = try setupMock(tempURL: tempURL)

        // move the CLI plugin elsewhere and symlink it
        let otherTempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: otherTempURL) }
        try FileManager.default.createDirectory(at: otherTempURL, withIntermediateDirectories: true)
        let srcURL = tempURL.appendingPathComponent("cli")
        let dstURL = otherTempURL.appendingPathComponent("cli")
        try FileManager.default.moveItem(
            at: srcURL,
            to: dstURL
        )
        try FileManager.default.createSymbolicLink(
            at: srcURL,
            withDestinationURL: dstURL
        )

        let loader = try PluginLoader(
            appRoot: tempURL,
            installRoot: URL(filePath: "/usr/local/"),
            logRoot: nil,
            pluginDirectories: [tempURL],
            pluginFactories: [factory]
        )
        let plugins = loader.findPlugins()

        #expect(Set(plugins.map { $0.name }) == Set(["cli", "service"]))
    }

    @Test
    func testFindByName() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let factory = try setupMock(tempURL: tempURL)
        let loader = try PluginLoader(
            appRoot: tempURL,
            installRoot: URL(filePath: "/usr/local/"),
            logRoot: nil,
            pluginDirectories: [tempURL],
            pluginFactories: [factory]
        )

        #expect(loader.findPlugin(name: "cli")?.name == "cli")
        #expect(loader.findPlugin(name: "service")?.name == "service")
        #expect(loader.findPlugin(name: "throw") == nil)
    }

    @Test
    func testFilterEnvironmentWithContainerPrefix() async throws {
        let env = [
            "CONTAINER_FOO": "bar",
            "CONTAINER_BAZ": "qux",
            "OTHER_VAR": "value",
        ]
        let filtered = PluginLoader.filterEnvironment(env: env, additionalAllowKeys: [])

        #expect(filtered == ["CONTAINER_FOO": "bar", "CONTAINER_BAZ": "qux"])
    }

    @Test
    func testFilterEnvironmentWithProxyKeys() async throws {
        let env = [
            "http_proxy": "http://proxy:8080",
            "HTTP_PROXY": "http://proxy:8080",
            "https_proxy": "https://proxy:8443",
            "HTTPS_PROXY": "https://proxy:8443",
            "no_proxy": "localhost,127.0.0.1",
            "NO_PROXY": "localhost,127.0.0.1",
            "OTHER_VAR": "value",
        ]
        let filtered = PluginLoader.filterEnvironment(env: env)

        #expect(
            filtered == [
                "http_proxy": "http://proxy:8080",
                "HTTP_PROXY": "http://proxy:8080",
                "https_proxy": "https://proxy:8443",
                "HTTPS_PROXY": "https://proxy:8443",
                "no_proxy": "localhost,127.0.0.1",
                "NO_PROXY": "localhost,127.0.0.1",
            ])
    }

    @Test
    func testFilterEnvironmentWithBothContainerAndProxy() async throws {
        let env = [
            "CONTAINER_FOO": "bar",
            "http_proxy": "http://proxy:8080",
            "OTHER_VAR": "value",
            "ANOTHER_VAR": "value2",
        ]
        let filtered = PluginLoader.filterEnvironment(env: env)

        #expect(
            filtered == [
                "CONTAINER_FOO": "bar",
                "http_proxy": "http://proxy:8080",
            ])
    }

    @Test
    func testFilterEnvironmentWithCustomAllowKeys() async throws {
        let env = [
            "CONTAINER_FOO": "bar",
            "CUSTOM_KEY": "custom_value",
            "OTHER_VAR": "value",
        ]
        let filtered = PluginLoader.filterEnvironment(env: env, additionalAllowKeys: ["CUSTOM_KEY"])

        #expect(
            filtered == [
                "CONTAINER_FOO": "bar",
                "CUSTOM_KEY": "custom_value",
            ])
    }

    #if CONTAINER_COVERAGE
    @Test
    func testFilterEnvironmentWithLLVMProfileFile() async throws {
        let env = [
            "LLVM_PROFILE_FILE": "/tmp/coverage/%p-%m%c.profraw",
            "OTHER_VAR": "value",
        ]
        let filtered = PluginLoader.filterEnvironment(env: env)

        #expect(filtered == ["LLVM_PROFILE_FILE": "/tmp/coverage/%p-%m%c.profraw"])
    }
    #endif

    @Test
    func testFilterEnvironmentEmpty() async throws {
        let filtered = PluginLoader.filterEnvironment(env: [:])

        #expect(filtered.isEmpty)
    }

    @Test
    func testFilterEnvironmentNoMatches() async throws {
        let env = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "USER": "testuser",
        ]
        let filtered = PluginLoader.filterEnvironment(env: env, additionalAllowKeys: [])

        #expect(filtered.isEmpty)
    }

    @Test
    func testRegisterWithLaunchdDebugTrue() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let serviceRoot = tempURL.appendingPathComponent("service-root", isDirectory: true)
        let factory = try setupMock(tempURL: tempURL)
        let loader = try PluginLoader(
            appRoot: tempURL,
            installRoot: URL(filePath: "/usr/local/"),
            logRoot: nil,
            pluginDirectories: [tempURL],
            pluginFactories: [factory],
            serviceRoot: serviceRoot
        )

        let plugin = loader.findPlugin(name: "service")!
        let stateRoot = tempURL.appendingPathComponent("test-state")
        try loader.registerWithLaunchd(plugin: plugin, pluginStateRoot: stateRoot, debug: true)

        let plistURL = serviceRoot.appending(path: "plugin-state/service/service.plist")
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let programArguments = plist["ProgramArguments"] as! [String]

        #expect(programArguments.contains("--debug"))
    }

    @Test
    func testRegisterWithLaunchdDebugFalse() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let serviceRoot = tempURL.appendingPathComponent("service-root", isDirectory: true)
        let factory = try setupMock(tempURL: tempURL)
        let loader = try PluginLoader(
            appRoot: tempURL,
            installRoot: URL(filePath: "/usr/local/"),
            logRoot: nil,
            pluginDirectories: [tempURL],
            pluginFactories: [factory],
            serviceRoot: serviceRoot
        )

        let plugin = loader.findPlugin(name: "service")!
        let stateRoot = tempURL.appendingPathComponent("test-state")
        try loader.registerWithLaunchd(plugin: plugin, pluginStateRoot: stateRoot, debug: false)

        let plistURL = serviceRoot.appending(path: "plugin-state/service/service.plist")
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let programArguments = plist["ProgramArguments"] as! [String]

        #expect(!programArguments.contains("--debug"))
    }

    @Test
    func testRegisterWithLaunchdDebugDefault() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let serviceRoot = tempURL.appendingPathComponent("service-root", isDirectory: true)
        let factory = try setupMock(tempURL: tempURL)
        let loader = try PluginLoader(
            appRoot: tempURL,
            installRoot: URL(filePath: "/usr/local/"),
            logRoot: nil,
            pluginDirectories: [tempURL],
            pluginFactories: [factory],
            serviceRoot: serviceRoot
        )

        let plugin = loader.findPlugin(name: "service")!
        let stateRoot = tempURL.appendingPathComponent("test-state")
        try loader.registerWithLaunchd(plugin: plugin, pluginStateRoot: stateRoot)

        let plistURL = serviceRoot.appending(path: "plugin-state/service/service.plist")
        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let programArguments = plist["ProgramArguments"] as! [String]

        #expect(!programArguments.contains("--debug"))
    }

    // MARK: - External volume plist placement tests

    /// When serviceRoot is separate from appRoot, the plist must land under
    /// serviceRoot and NOT under appRoot — which might be on an external or
    /// removable volume where launchd cannot register Mach services.
    @Test
    func testRegisterWithLaunchdInstancedPlistsStayUnderServiceRoot() async throws {
        let appRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appRootURL) }

        // serviceRoot is distinct from appRoot, simulating the case where appRoot
        // is on an external volume but serviceRoot is on the internal system volume.
        let serviceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: serviceRootURL) }

        let factory = try setupMock(tempURL: appRootURL)
        let loader = try PluginLoader(
            appRoot: appRootURL,
            installRoot: URL(filePath: "/usr/local/"),
            logRoot: nil,
            pluginDirectories: [appRootURL],
            pluginFactories: [factory],
            serviceRoot: serviceRootURL
        )

        let plugin = loader.findPlugin(name: "service")!
        let externalStateRoot = appRootURL.appendingPathComponent("runtime-state", isDirectory: true)
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: externalStateRoot,
            instanceId: "default"
        )
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: externalStateRoot,
            instanceId: "secondary"
        )

        let defaultPlistURL =
            serviceRootURL
            .appendingPathComponent("plugin-state", isDirectory: true)
            .appending(path: plugin.name)
            .appending(path: "default")
            .appendingPathComponent("service.plist")
        let secondaryPlistURL =
            serviceRootURL
            .appendingPathComponent("plugin-state", isDirectory: true)
            .appending(path: plugin.name)
            .appending(path: "secondary")
            .appendingPathComponent("service.plist")

        // Each instance gets a distinct plist under serviceRoot (internal volume).
        #expect(FileManager.default.fileExists(atPath: defaultPlistURL.path))
        #expect(FileManager.default.fileExists(atPath: secondaryPlistURL.path))

        // pluginStateRoot may be external and must never contain a launchd plist.
        #expect(!FileManager.default.fileExists(atPath: externalStateRoot.appendingPathComponent("service.plist").path))

        // An explicitly supplied serviceRoot is propagated to the child service.
        let plistData = try Data(contentsOf: defaultPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let environment = plist["EnvironmentVariables"] as! [String: String]
        #expect(environment[ServiceRoot.environmentName] == serviceRootURL.path(percentEncoded: false))
    }

    private func setupMock(tempURL: URL) throws -> MockPluginFactory {
        let cliConfig = PluginConfig(abstract: "cli", author: "CLI", servicesConfig: nil)
        let cliPlugin: Plugin = Plugin(binaryURL: URL(filePath: "/bin/cli"), config: cliConfig)
        let serviceServicesConfig = PluginConfig.ServicesConfig(
            loadAtBoot: false,
            runAtLoad: false,
            services: [PluginConfig.Service(type: .runtime, description: nil)],
            defaultArguments: []
        )
        let serviceConfig = PluginConfig(abstract: "service", author: "SERVICE", servicesConfig: serviceServicesConfig)
        let servicePlugin: Plugin = Plugin(binaryURL: URL(filePath: "/bin/service"), config: serviceConfig)
        let mockPlugins = [
            "cli": cliPlugin,
            MockPluginFactory.throwSuffix: nil,
            "service": servicePlugin,
        ]

        return try MockPluginFactory(tempURL: tempURL, plugins: mockPlugins)
    }
}
