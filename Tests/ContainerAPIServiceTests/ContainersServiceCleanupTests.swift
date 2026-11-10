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
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerTestSupport
import Foundation
import Logging
import Testing

struct ContainersServiceCleanupTests {
    private enum Runtime {
        case installed
        case missing
    }

    private enum Removal {
        case auto
        case manual
    }

    private static let runtimeName = "container-runtime-linux"
    private static let argsFilename = "cleanup-args"

    private static let runtimeConfig = """
        abstract = "test runtime"

        [servicesConfig]
        loadAtBoot = false
        runAtLoad = false
        defaultArguments = []

        [[servicesConfig.services]]
        type = "runtime"
        """

    private let log = Logger(label: "test")

    /// Installs a runtime plugin whose cleanup records its arguments in `appRoot/cleanup-args`.
    private static func installRuntime(appRoot: URL) throws -> URL {
        let plugins = appRoot.appendingPathComponent("plugins")
        let bin = plugins.appendingPathComponent(runtimeName).appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try runtimeConfig.write(to: plugins.appendingPathComponent(runtimeName).appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let binary = bin.appendingPathComponent(runtimeName)
        let args = appRoot.appendingPathComponent(argsFilename).path
        try "#!/bin/sh\necho \"$@\" > '\(args)'\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return plugins
    }

    private static func createBundle(appRoot: URL, id: String, removal: Removal) throws -> URL {
        let path = appRoot.appendingPathComponent("containers").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        let bundle = ContainerResource.Bundle(path: path)
        try bundle.write(filename: "config.json", value: ContainerConfiguration(id: id, image: image, process: process))
        try bundle.write(filename: "options.json", value: ContainerCreateOptions(autoRemove: removal == .auto))
        return path
    }

    private func makeService(appRoot: URL, runtime: Runtime) async throws -> ContainersService {
        let pluginDirectories = try runtime == .installed ? [Self.installRuntime(appRoot: appRoot)] : []
        let pluginLoader = try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: pluginDirectories,
            pluginFactories: [DefaultPluginFactory(logger: log)]
        )
        return try await ContainersService(
            appRoot: appRoot,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log
        )
    }

    private static func cleanupArgs(appRoot: URL) -> String? {
        try? String(contentsOf: appRoot.appendingPathComponent(argsFilename), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expectCleanup(appRoot: URL, id: String) throws {
        let args = try #require(cleanupArgs(appRoot: appRoot))
        #expect(args.hasPrefix("cleanup --root "))
        #expect(args.hasSuffix("/containers/\(id) --uuid \(id)"))
    }

    @Test
    func bootReapRunsCleanup() async throws {
        try await TemporaryStorage.withTempDir { root in
            let appRoot = URL(fileURLWithPath: root.string)
            let id = "reap-\(UUID())"
            let bundle = try Self.createBundle(appRoot: appRoot, id: id, removal: .auto)

            let service = try await makeService(appRoot: appRoot, runtime: .installed)

            try Self.expectCleanup(appRoot: appRoot, id: id)
            #expect(!FileManager.default.fileExists(atPath: bundle.path))
            #expect(try await service.list().isEmpty)
        }
    }

    @Test
    func deleteRunsCleanup() async throws {
        try await TemporaryStorage.withTempDir { root in
            let appRoot = URL(fileURLWithPath: root.string)
            let id = "delete-\(UUID())"
            let bundle = try Self.createBundle(appRoot: appRoot, id: id, removal: .manual)

            let service = try await makeService(appRoot: appRoot, runtime: .installed)
            #expect(Self.cleanupArgs(appRoot: appRoot) == nil)

            try await service.delete(id: id, force: false)

            try Self.expectCleanup(appRoot: appRoot, id: id)
            #expect(!FileManager.default.fileExists(atPath: bundle.path))
            #expect(try await service.list().isEmpty)
        }
    }

    @Test
    func bootDropsContainerWithMissingRuntime() async throws {
        try await TemporaryStorage.withTempDir { root in
            let appRoot = URL(fileURLWithPath: root.string)
            let bundle = try Self.createBundle(appRoot: appRoot, id: "orphan-\(UUID())", removal: .auto)

            let service = try await makeService(appRoot: appRoot, runtime: .missing)

            #expect(Self.cleanupArgs(appRoot: appRoot) == nil)
            #expect(!FileManager.default.fileExists(atPath: bundle.path))
            #expect(try await service.list().isEmpty)
        }
    }
}
