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
import ContainerResource
import ContainerVersion
import ContainerizationError
import ContainerizationOCI
import Foundation
import MachineAPIClient
import SystemPackage
import Testing

@testable import ContainerCompose

struct MachineConfigurationTests {
    @Test
    func composeConfigurationUsesDaemonRoots() throws {
        let health = try JSONDecoder().decode(
            SystemHealth.self,
            from: Data(#"{"appRoot":"/tmp/app","installRoot":"/tmp/install","logRoot":null,"apiServerVersion":"test","apiServerCommit":"test","apiServerBuild":"debug","apiServerAppName":"test"}"#.utf8)
        )
        let files = ComposeMachineManager.configurationFiles(for: health)
        #expect(files.map(\.string) == [
            "/tmp/app/config/config.toml",
            "/tmp/install/etc/container/config.toml",
        ])
    }

    @Test
    func idleShutdownSecondsDecodeFromConfiguration() throws {
        let data = Data(#"{"idle-shutdown-seconds":600}"#.utf8)
        let configuration = try JSONDecoder().decode(ComposeConfiguration.self, from: data)
        #expect(configuration.idleShutdownSeconds == 600)
    }

    @Test
    func defaultComposeImageIsAccepted() {
        #expect(ComposeConfiguration.defaultImage == "container-compose-machine:local")
        #expect(ComposeConfiguration.isValidImage(ComposeConfiguration.defaultImage))
    }

    @Test
    func customComposeImageReferenceIsAccepted() {
        #expect(ComposeConfiguration.isValidImage("registry.example/compose-machine:dev"))
        #expect(ComposeConfiguration.isValidImage("registry.example/compose-machine@sha256:\(String(repeating: "a", count: 64))"))
        #expect(!ComposeConfiguration.isValidImage("not a reference"))
    }

    @Test
    func emptyComposeImageIsRejected() {
        #expect(!ComposeConfiguration.isValidImage(""))
    }

    @Test
    func installedImageResourcesUseSiblingPluginResources() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-plugin")
        let executable = FilePath(root.appendingPathComponent("bin/compose").path)
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: resources.appendingPathComponent("Containerfile"))
        try Data().write(to: resources.appendingPathComponent("container-compose-idle-shutdown"))
        try Data().write(to: resources.appendingPathComponent("container-compose-idle-shutdown.service"))

        let found = try ComposeMachineImageResources.locate(
            executablePath: executable,
            mainResourceURL: nil,
            moduleResourceURL: nil
        )
        #expect(found.directory.path == resources.path)
    }

    @Test
    func missingImageResourceReportsRequiredFiles() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-missing-resources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Containerfile"))

        #expect(throws: ContainerizationError.self) {
            try ComposeMachineImageResources.locate(
                executablePath: FilePath("/unrelated/compose"),
                mainResourceURL: nil,
                moduleResourceURL: root
            )
        }
    }

    @Test
    func moduleResourcesCanBeInjectedForResolutionTests() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-module")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Containerfile"))
        try Data().write(to: root.appendingPathComponent("container-compose-idle-shutdown"))
        try Data().write(to: root.appendingPathComponent("container-compose-idle-shutdown.service"))

        let found = try ComposeMachineImageResources.locate(
            executablePath: FilePath("/unrelated/compose"),
            mainResourceURL: nil,
            moduleResourceURL: root
        )
        #expect(found.directory.path == root.path)
    }

    @Test
    func backingContainerTokenRoundTrips() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-machine-token")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let token = UUID().uuidString.lowercased()
        try token.write(
            toFile: root.appendingPathComponent(MachineBundle.backingContainerTokenFile.string).path,
            atomically: true,
            encoding: .utf8
        )
        #expect(try MachineBundle(path: FilePath(root.path)).backingContainerToken() == token)
    }

    @Test
    func missingBackingContainerTokenIsNotMigrated() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-machine-token-missing")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ContainerizationError.self) {
            _ = try MachineBundle(path: FilePath(root.path)).backingContainerToken()
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(MachineBundle.backingContainerTokenFile.string).path
            ))
    }

    @Test
    func missingBackingContainerTokenCanBeAbsentForLegacyMachines() throws {
        let root = URL(fileURLWithPath: "/tmp/legacy-machine-token-missing")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try MachineBundle(path: FilePath(root.path)).backingContainerTokenIfPresent() == nil)
    }

    @Test
    func composeOwnershipMarkerRoundTrips() throws {
        let image = ImageDescription(
            reference: "container-compose-machine:local",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let configuration = try MachineConfiguration(
            id: "compose",
            image: image,
            platform: .current,
            userSetup: UserSetup(username: "tester", uid: 501, gid: 20),
            managedBy: "compose"
        )

        let decoded = try JSONDecoder().decode(
            MachineConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded.managedBy == "compose")
    }

    @Test
    func legacyMachineConfigurationHasNoOwner() throws {
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "1", count: 64),
                size: 0
            )
        )
        let configuration = try MachineConfiguration(
            id: "legacy",
            image: image,
            platform: .current,
            userSetup: UserSetup(username: "tester", uid: 501, gid: 20)
        )
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(configuration)
            ) as? [String: Any]
        )
        var legacyObject = object
        legacyObject.removeValue(forKey: "managedBy")
        let decoded = try JSONDecoder().decode(
            MachineConfiguration.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(decoded.managedBy == nil)
    }
}
