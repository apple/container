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
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

struct LoadAtBootExitStatusTests {
    private struct RuntimePluginFactory: PluginFactory {
        func create(installURL: URL) throws -> Plugin? {
            nil
        }

        func create(parentURL: URL, name: String) throws -> Plugin? {
            guard name == "container-runtime-linux" else {
                return nil
            }
            let services = PluginConfig.ServicesConfig(
                loadAtBoot: false,
                runAtLoad: false,
                services: [PluginConfig.Service(type: .runtime, description: nil)],
                defaultArguments: []
            )
            let config = PluginConfig(abstract: "runtime", author: "test", servicesConfig: services)
            return Plugin(binaryURL: URL(filePath: "/bin/\(name)"), config: config)
        }
    }

    private func makeConfiguration(id: String) -> ContainerConfiguration {
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
        return ContainerConfiguration(id: id, image: image, process: process)
    }

    private func loadContainers(_ ids: [String], exits: [String: ExitRecord] = [:], garbage: Set<String> = []) throws -> [String: ContainersService.ContainerState] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("test-boot-\(UUID().uuidString)")
        let containers = root.appendingPathComponent("containers")
        let plugins = root.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(
            at: plugins.appendingPathComponent("container-runtime-linux"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        for id in ids {
            let directory = containers.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bundle = ContainerResource.Bundle(path: directory)
            try bundle.set(configuration: makeConfiguration(id: id))
            if let exit = exits[id] {
                try bundle.setExitStatus(exit)
            }
            if garbage.contains(id) {
                try Data("not json".utf8).write(to: bundle.filePath(for: "exit.json"))
            }
        }
        let loader = try PluginLoader(
            appRoot: root,
            installRoot: root,
            logRoot: nil,
            pluginDirectories: [plugins],
            pluginFactories: [RuntimePluginFactory()]
        )
        return try ContainersService.loadAtBoot(root: containers, loader: loader, log: Logger(label: "test"))
    }

    @Test
    func stoppedContainersComeBackWithTheirRecordedExit() throws {
        let exitedAt = Date(timeIntervalSinceReferenceDate: 812_571_436)
        let loaded = try loadContainers(
            ["failed", "succeeded", "never-ran"],
            exits: [
                "failed": ExitRecord(exitCode: 7, exitedAt: exitedAt),
                "succeeded": ExitRecord(exitCode: 0, exitedAt: exitedAt),
            ])

        #expect(loaded["failed"]?.snapshot.status == .stopped)
        #expect(loaded["failed"]?.snapshot.exitCode == 7)
        #expect(loaded["failed"]?.snapshot.exitedAt == exitedAt)
        #expect(loaded["succeeded"]?.snapshot.exitCode == 0)
        #expect(loaded["never-ran"]?.snapshot.exitCode == nil)
        #expect(loaded["never-ran"]?.snapshot.exitedAt == nil)
    }

    @Test
    func anUnreadableRecordDoesNotKeepTheContainerFromLoading() throws {
        let loaded = try loadContainers(["damaged"], garbage: ["damaged"])

        #expect(loaded["damaged"]?.snapshot.status == .stopped)
        #expect(loaded["damaged"]?.snapshot.exitCode == nil)
    }
}
