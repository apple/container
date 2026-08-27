//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerPersistence
import ContainerResource
import ContainerTestSupport
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

private struct InstanceTokenTestPluginFactory: PluginFactory {
    let plugin: Plugin

    func create(installURL: URL) throws -> Plugin? {
        plugin
    }

    func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }
}

struct ContainerInstanceTokenTests {
    private let log = Logger(label: "container-instance-token-tests")

    @Test func survivesServiceReconstruction() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let token = "persisted-instance-token"
            try writeContainer(id: "restart-test", token: token, appRoot: appRoot)

            let firstService = try makeService(appRoot: appRoot)
            let firstSnapshots = try await firstService.list()
            let first = try #require(firstSnapshots.first)
            #expect(first.configuration.instanceToken == token)

            let restartedService = try makeService(appRoot: appRoot)
            let restartedSnapshots = try await restartedService.list()
            let restarted = try #require(restartedSnapshots.first)
            #expect(restarted.configuration.instanceToken == token)
        }
    }

    @Test func conditionalDeleteRejectsMismatchWithoutDeleting() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let id = "mismatch-test"
            try writeContainer(id: id, token: "current-token", appRoot: appRoot)
            let service = try makeService(appRoot: appRoot)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.delete(id: id, force: false, expectedInstanceToken: "stale-token")
            }

            #expect(error?.code == .invalidState)
            let snapshots = try await service.list()
            #expect(snapshots.map(\.id) == [id])
        }
    }

    @Test func staleTokenCannotDeleteReplacementWithReusedID() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let id = "reused-id"
            let firstToken = "first-incarnation-token"
            let firstBundlePath = try writeContainer(id: id, token: firstToken, appRoot: appRoot)
            let firstService = try makeService(appRoot: appRoot)

            try FileManager.default.removeItem(at: firstBundlePath.appendingPathComponent("config.json"))
            try await firstService.delete(id: id, force: false, expectedInstanceToken: firstToken)

            let replacementToken = "replacement-incarnation-token"
            try writeContainer(id: id, token: replacementToken, appRoot: appRoot)
            let replacementService = try makeService(appRoot: appRoot)

            let error = await #expect(throws: ContainerizationError.self) {
                try await replacementService.delete(id: id, force: false, expectedInstanceToken: firstToken)
            }

            #expect(error?.code == .invalidState)
            let snapshots = try await replacementService.list()
            #expect(snapshots.first?.configuration.instanceToken == replacementToken)
        }
    }

    @Test func conditionalDeleteRejectsTokenFromAnotherContainer() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            try writeContainer(id: "first", token: "first-token", appRoot: appRoot)
            try writeContainer(id: "second", token: "second-token", appRoot: appRoot)
            let service = try makeService(appRoot: appRoot)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.delete(id: "first", force: false, expectedInstanceToken: "second-token")
            }

            #expect(error?.code == .invalidState)
            let snapshots = try await service.list()
            #expect(Set(snapshots.map(\.id)) == Set(["first", "second"]))
        }
    }

    @Test func conditionalDeleteWithMatchingTokenSucceeds() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let id = "matching-test"
            let token = "matching-token"
            let bundlePath = try writeContainer(id: id, token: token, appRoot: appRoot)
            let service = try makeService(appRoot: appRoot)

            // Avoid touching launchd in this focused unit test. The in-memory
            // snapshot remains authoritative for the instance check.
            try FileManager.default.removeItem(at: bundlePath.appendingPathComponent("config.json"))
            try await service.delete(id: id, force: false, expectedInstanceToken: token)

            let snapshots = try await service.list()
            #expect(snapshots.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: bundlePath.path))
        }
    }

    @Test func legacyDeleteRemainsCompatibleAndConditionalDeleteFailsClosed() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let id = "legacy-test"
            let bundlePath = try writeContainer(id: id, token: nil, appRoot: appRoot)
            let service = try makeService(appRoot: appRoot)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.delete(id: id, force: false, expectedInstanceToken: "caller-token")
            }
            #expect(error?.code == .invalidState)
            let preservedSnapshots = try await service.list()
            #expect(preservedSnapshots.count == 1)

            try FileManager.default.removeItem(at: bundlePath.appendingPathComponent("config.json"))
            try await service.delete(id: id, force: false)
            let deletedSnapshots = try await service.list()
            #expect(deletedSnapshots.isEmpty)
        }
    }

    @Test func conditionalDeleteRouteRejectsMissingToken() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let id = "missing-token-test"
            try writeContainer(id: id, token: "current-token", appRoot: appRoot)
            let service = try makeService(appRoot: appRoot)
            let harness = ContainersHarness(service: service, log: log)
            let request = XPCMessage(route: .containerDeleteIfInstance)
            request.set(key: .id, value: id)

            let error = await #expect(throws: ContainerizationError.self) {
                _ = try await harness.deleteIfInstance(request)
            }

            #expect(error?.code == .invalidArgument)
            let snapshots = try await service.list()
            #expect(snapshots.map(\.id) == [id])
        }
    }

    @Test func delayedExitFromForceDeletedInstanceDoesNotMutateReplacementAcrossRestart() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let id = "delayed-exit-reuse"
            let oldToken = "old-instance-token"
            let oldBundlePath = try writeContainer(id: id, token: oldToken, appRoot: appRoot)
            let oldService = try makeService(appRoot: appRoot)

            // Exercise force-request cleanup without touching launchd, then
            // reconstruct the service around an immediate same-ID replacement.
            try FileManager.default.removeItem(at: oldBundlePath.appendingPathComponent("config.json"))
            try await oldService.delete(id: id, force: true, expectedInstanceToken: oldToken)

            let replacementToken = "replacement-instance-token"
            let replacementBundlePath = try writeContainer(id: id, token: replacementToken, appRoot: appRoot)
            let restartedService = try makeService(appRoot: appRoot)
            try await restartedService.setContainerStatusForTesting(id: id, status: .running)

            try await restartedService.handleContainerExit(
                id: id,
                expectedInstanceToken: oldToken,
                code: ExitStatus(exitCode: 0)
            )

            let snapshots = try await restartedService.list()
            let replacement = try #require(snapshots.first)
            #expect(replacement.configuration.instanceToken == replacementToken)
            #expect(replacement.status == .running)
            #expect(FileManager.default.fileExists(atPath: replacementBundlePath.path))
        }
    }

    private func makeService(appRoot: FilePath) throws -> ContainersService {
        let appRootURL = URL(fileURLWithPath: appRoot.string)
        let pluginDirectory = appRootURL.appendingPathComponent("plugins")
        let installURL = pluginDirectory.appendingPathComponent("container-runtime-linux")
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)

        let servicesConfig = PluginConfig.ServicesConfig(
            loadAtBoot: false,
            runAtLoad: false,
            services: [.init(type: .runtime, description: nil)],
            defaultArguments: []
        )
        let plugin = Plugin(
            binaryURL: URL(fileURLWithPath: "/bin/container-runtime-linux"),
            config: PluginConfig(abstract: "test runtime", author: nil, servicesConfig: servicesConfig)
        )
        let loader = try PluginLoader(
            appRoot: appRootURL,
            installRoot: appRootURL,
            logRoot: nil,
            pluginDirectories: [pluginDirectory],
            pluginFactories: [InstanceTokenTestPluginFactory(plugin: plugin)]
        )
        return try ContainersService(
            appRoot: appRootURL,
            pluginLoader: loader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log
        )
    }

    @discardableResult
    private func writeContainer(id: String, token: String?, appRoot: FilePath) throws -> URL {
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
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.instanceToken = token

        let bundlePath = URL(fileURLWithPath: appRoot.string)
            .appendingPathComponent("containers")
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
        try Bundle(path: bundlePath).set(configuration: configuration)
        return bundlePath
    }
}
