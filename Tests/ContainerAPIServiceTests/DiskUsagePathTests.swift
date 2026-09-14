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

import ContainerAPIClient
import ContainerAPIService
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerTestSupport
import ContainerXPC
import ContainerizationError
import Foundation
import Logging
import SystemPackage
import Testing

struct DiskUsagePathTests {
    private let log = Logger(label: "test")

    private func makeContainersService(appRoot: FilePath) throws -> ContainersService {
        let appRoot = URL(fileURLWithPath: appRoot.string)
        let pluginLoader = try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: [],
            pluginFactories: []
        )
        return try ContainersService(
            appRoot: appRoot,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log
        )
    }

    private func makeVolumesService(appRoot: FilePath) async throws -> VolumesService {
        try await VolumesService(
            resourceRoot: appRoot.appending("volumes"),
            containersService: makeContainersService(appRoot: appRoot),
            log: log
        )
    }

    @Test(
        "diskUsage rejects container identifiers with path separators or traversal",
        arguments: ["..", "../", "../../etc/passwd", "/etc/passwd", "a/b"]
    )
    func containerDiskUsageRejectsUnsafeIdentifier(_ id: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let harness = ContainersHarness(service: try makeContainersService(appRoot: appRoot), log: log)
            let message = XPCMessage(route: XPCRoute.containerDiskUsage)
            message.set(key: .id, value: id)

            let error = await #expect(throws: ContainerizationError.self) {
                _ = try await harness.diskUsage(message)
            }
            #expect(error?.code == .invalidArgument)
        }
    }

    @Test(
        "volumeDiskUsage rejects names with path separators or traversal",
        arguments: ["../containers", "..", "../../etc/passwd", "/etc/passwd", "a/b"]
    )
    func volumeDiskUsageRejectsUnsafeName(_ name: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: VolumeError.self) {
                _ = try await service.volumeDiskUsage(name: name)
            }
        }
    }

    @Test("volumeDiskUsage reports the size of a valid volume")
    func volumeDiskUsageReportsSizeForValidName() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            let volumeDirectory = URL(fileURLWithPath: appRoot.appending("volumes/myvol").string)
            try FileManager.default.createDirectory(at: volumeDirectory, withIntermediateDirectories: true)
            try Data("volume contents".utf8).write(to: volumeDirectory.appendingPathComponent("data"))

            let size = try await service.volumeDiskUsage(name: "myvol")
            #expect(size > 0)
        }
    }
}
