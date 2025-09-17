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
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import Synchronization
import SystemPackage

public actor VolumesService {
    private let resourceRoot: URL
    private let store: ContainerPersistence.FilesystemEntityStore<Volume>
    private let log: Logger
    private let lock = AsyncLock()
    private let containersService: ContainersService

    // Storage constants
    private static let entityFile = "entity.json"
    private static let blockFile = "volume.img"

    public init(resourceRoot: URL, containersService: ContainersService, log: Logger) throws {
        try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
        self.resourceRoot = resourceRoot
        self.store = try FilesystemEntityStore<Volume>(path: resourceRoot, type: "volumes", log: log)
        self.containersService = containersService
        self.log = log
    }

    public func create(
        name: String,
        driver: String = "local",
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:]
    ) async throws -> Volume {
        try await lock.withLock { _ in
            try await self._create(name: name, driver: driver, driverOpts: driverOpts, labels: labels)
        }
    }

    public func delete(name: String) async throws {
        try await lock.withLock { _ in
            try await self._delete(name: name)
        }
    }

    public func list() async throws -> [Volume] {
        try await store.list()
    }

    public func inspect(_ name: String) async throws -> Volume {
        try await lock.withLock { _ in
            try await self._inspect(name)
        }
    }

    private func parseSize(_ sizeString: String) throws -> UInt64 {
        let measurement = try Measurement.parse(parsing: sizeString)
        let bytes = measurement.converted(to: .bytes).value

        // Validate minimum size
        let minSize: UInt64 = 1.mib()  // 1mib minimum

        let sizeInBytes = UInt64(bytes)

        guard sizeInBytes >= minSize else {
            throw VolumeError.storageError("Volume size too small: minimum 1MiB")
        }

        return sizeInBytes
    }

    private nonisolated func volumePath(for name: String) -> String {
        resourceRoot.appendingPathComponent(name).path
    }

    private nonisolated func entityPath(for name: String) -> String {
        "\(volumePath(for: name))/\(Self.entityFile)"
    }

    private nonisolated func blockPath(for name: String) -> String {
        "\(volumePath(for: name))/\(Self.blockFile)"
    }

    private func createVolumeDirectory(for name: String) throws {
        let volumePath = volumePath(for: name)
        let fm = FileManager.default
        try fm.createDirectory(atPath: volumePath, withIntermediateDirectories: true, attributes: nil)
    }

    private func createVolumeImage(for name: String, sizeInBytes: UInt64 = VolumeStorage.defaultVolumeSizeBytes) throws {
        let blockPath = blockPath(for: name)

        // Use the containerization library's EXT4 formatter
        let formatter = try EXT4.Formatter(
            FilePath(blockPath),
            blockSize: 4096,
            minDiskSize: sizeInBytes
        )

        try formatter.close()
    }

    private nonisolated func removeVolumeDirectory(for name: String) throws {
        let volumePath = volumePath(for: name)
        let fm = FileManager.default

        if fm.fileExists(atPath: volumePath) {
            try fm.removeItem(atPath: volumePath)
        }
    }

    private func _create(
        name: String,
        driver: String,
        driverOpts: [String: String],
        labels: [String: String]
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

        // Parse size from driver options (default 512GB)
        let sizeInBytes: UInt64
        if let sizeString = driverOpts["size"] {
            sizeInBytes = try parseSize(sizeString)
        } else {
            sizeInBytes = VolumeStorage.defaultVolumeSizeBytes
        }

        try createVolumeImage(for: name, sizeInBytes: sizeInBytes)

        let volume = Volume(
            name: name,
            driver: driver,
            format: "ext4",
            source: blockPath(for: name),
            labels: labels,
            options: driverOpts
        )

        try await store.create(volume)

        log.info("Created volume", metadata: ["name": "\(name)", "driver": "\(driver)"])
        return volume
    }

    private func _delete(name: String) async throws {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("Invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        // Check if volume exists by trying to list and finding it
        let existingVolumes = try await store.list()
        guard existingVolumes.contains(where: { $0.name == name }) else {
            throw VolumeError.volumeNotFound(name)
        }

        // Check if volume is in use by any container atomically
        try await containersService.withContainerList { containers in
            for container in containers {
                for mount in container.configuration.mounts {
                    if mount.isVolume && mount.volumeName == name {
                        throw VolumeError.volumeInUse(name)
                    }
                }
            }

            try await self.store.delete(name)
            try self.removeVolumeDirectory(for: name)
        }

        log.info("Deleted volume", metadata: ["name": "\(name)"])
    }

    private func _inspect(_ name: String) async throws -> Volume {
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
