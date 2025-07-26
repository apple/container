//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerClient
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

actor VolumesService {
    private let resourceRoot: URL
    private let store: ContainerPersistence.FilesystemEntityStore<Volume>
    private let log: Logger

    // Storage constants
    private static let entityFile = "entity.json"
    private static let blockFile = "volume.img"

    public init(resourceRoot: URL, log: Logger) throws {
        try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
        self.resourceRoot = resourceRoot
        self.store = try FilesystemEntityStore<Volume>(path: resourceRoot, type: "volumes", log: log)
        self.log = log
    }

    // MARK: - Storage Utilities

    private func volumePath(for name: String) -> String {
        resourceRoot.appendingPathComponent(name).path
    }

    private func entityPath(for name: String) -> String {
        "\(volumePath(for: name))/\(Self.entityFile)"
    }

    private func blockPath(for name: String) -> String {
        "\(volumePath(for: name))/\(Self.blockFile)"
    }

    private func createVolumeDirectory(for name: String) throws {
        let volumePath = volumePath(for: name)
        let fm = FileManager.default
        try fm.createDirectory(atPath: volumePath, withIntermediateDirectories: true, attributes: nil)
    }

    private func createVolumeImage(for name: String, sizeInBytes: UInt64 = 1024 * 1024 * 1024) throws {
        let blockPath = blockPath(for: name)
        
        // Use the containerization library's EXT4 formatter
        let formatter = try EXT4.Formatter(
            FilePath(blockPath),
            blockSize: 4096,
            minDiskSize: sizeInBytes
        )
        
        try formatter.close()
    }

    private func removeVolumeDirectory(for name: String) throws {
        let volumePath = volumePath(for: name)
        let fm = FileManager.default

        if fm.fileExists(atPath: volumePath) {
            try fm.removeItem(atPath: volumePath)
        }
    }

    public func create(
        name: String,
        driver: String = "local",
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:]
    ) async throws -> Volume {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("Invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        // Check if volume already exists by trying to list and finding it
        let existingVolumes = try await store.list()
        if existingVolumes.contains(where: { $0.name == name }) {
            throw VolumeError.volumeAlreadyExists(name)
        }

        try createVolumeDirectory(for: name)
        try createVolumeImage(for: name)

        let volume = Volume(
            name: name,
            driver: driver,
            source: blockPath(for: name),
            labels: labels,
            options: driverOpts
        )

        try await store.create(volume)

        log.info("Created volume", metadata: ["name": "\(name)", "driver": "\(driver)"])
        return volume
    }

    public func delete(name: String) async throws {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("Invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        // Check if volume exists by trying to list and finding it
        let existingVolumes = try await store.list()
        guard existingVolumes.contains(where: { $0.name == name }) else {
            throw VolumeError.volumeNotFound(name)
        }

        try await store.delete(name)
        try removeVolumeDirectory(for: name)

        log.info("Deleted volume", metadata: ["name": "\(name)"])
    }

    public func list() async throws -> [Volume] {
        try await store.list()
    }

    public func inspect(_ name: String) async throws -> Volume {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("Invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        let volumes = try await store.list()
        guard let volume = volumes.first(where: { $0.name == name }) else {
            throw VolumeError.volumeNotFound(name)
        }

        return volume
    }
}
