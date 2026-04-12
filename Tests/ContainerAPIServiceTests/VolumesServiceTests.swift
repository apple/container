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
import ContainerizationError
import Foundation
import Logging
import SystemPackage
import Testing

struct VolumesServiceTests {
    private let log = Logger(label: "test")

    private func makeVolumesService(appRoot: FilePath) async throws -> VolumesService {
        let appRootURL = URL(fileURLWithPath: appRoot.string)
        let pluginLoader = try PluginLoader(
            appRoot: appRootURL,
            installRoot: appRootURL,
            logRoot: nil,
            pluginDirectories: [],
            pluginFactories: []
        )
        let containersService = try ContainersService(
            appRoot: appRootURL,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log
        )
        return try await VolumesService(
            resourceRoot: appRoot.appending("volumes"),
            containersService: containersService,
            log: log
        )
    }

    @Test("VolumesService creates, inspects, and deletes an SMB volume without a disk image")
    func testCreateInspectDeleteSMBVolume() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            let created = try await service.create(
                name: "myshare",
                driver: "smb",
                driverOpts: ["share": "//server/share", "username": "user", "password": "secret"],
                labels: ["env": "test"]
            )

            #expect(created.name == "myshare")
            #expect(created.driver == "smb")
            #expect(created.format == "cifs")
            #expect(created.source == "//server/share")
            #expect(created.sizeInBytes == nil)
            #expect(created.options["username"] == "user")
            #expect(created.labels["env"] == "test")

            let blockImagePath = appRoot.appending("volumes/myshare/volume.img").string
            #expect(!FileManager.default.fileExists(atPath: blockImagePath))

            let inspected = try await service.inspect("myshare")
            #expect(inspected.name == "myshare")
            #expect(inspected.driver == "smb")
            #expect(inspected.source == "//server/share")

            try await service.delete(name: "myshare")
            await #expect(throws: VolumeError.self) {
                _ = try await service.inspect("myshare")
            }
        }
    }

    @Test("VolumesService creates, inspects, and deletes an NFS volume without a disk image")
    func testCreateInspectDeleteNFSVolume() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            let created = try await service.create(
                name: "myexport",
                driver: "nfs",
                driverOpts: ["share": "nas.local:/exports/data", "vers": "4", "nolock": ""],
                labels: ["env": "test"]
            )

            #expect(created.name == "myexport")
            #expect(created.driver == "nfs")
            #expect(created.format == "nfs")
            #expect(created.source == "nas.local:/exports/data")
            #expect(created.sizeInBytes == nil)
            #expect(created.options["vers"] == "4")
            #expect(created.options["nolock"] == "")
            #expect(created.labels["env"] == "test")

            let blockImagePath = appRoot.appending("volumes/myexport/volume.img").string
            #expect(!FileManager.default.fileExists(atPath: blockImagePath))

            let inspected = try await service.inspect("myexport")
            #expect(inspected.name == "myexport")
            #expect(inspected.driver == "nfs")
            #expect(inspected.source == "nas.local:/exports/data")

            try await service.delete(name: "myexport")
            await #expect(throws: VolumeError.self) {
                _ = try await service.inspect("myexport")
            }
        }
    }

    @Test(
        "VolumesService rejects SMB and NFS volumes with missing or empty share option",
        arguments: ["smb", "nfs"]
    )
    func testRejectsMissingOrEmptyShare(_ driver: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol1", driver: driver, driverOpts: [:])
            }

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol2", driver: driver, driverOpts: ["share": ""])
            }
        }
    }

    @Test(
        "VolumesService rejects unsupported size option for SMB and NFS volumes",
        arguments: [
            ("smb", "//server/share"),
            ("nfs", "nas.local:/exports/data"),
        ]
    )
    func testRejectsSizeOption(_ driver: String, _ share: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(
                    name: "vol1",
                    driver: driver,
                    driverOpts: ["share": share, "size": "10G"]
                )
            }
        }
    }

    @Test("VolumesService rejects unsupported volume driver")
    func testRejectsUnsupportedDriver() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol1", driver: "ceph", driverOpts: [:])
            }
        }
    }
}
