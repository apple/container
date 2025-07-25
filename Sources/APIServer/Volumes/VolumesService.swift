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
import Foundation
import Logging

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
        let fm = FileManager.default

        // Create sparse file
        fm.createFile(atPath: blockPath, contents: nil, attributes: nil)

        // Truncate to desired size to create sparse file
        let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: blockPath))
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: sizeInBytes)
    }

    private func removeVolumeDirectory(for name: String) throws {
        let volumePath = volumePath(for: name)
        let fm = FileManager.default

        if fm.fileExists(atPath: volumePath) {
            try fm.removeItem(atPath: volumePath)
        }
    }

    public func create(_ request: VolumeCreateRequest) async throws -> Volume {
        guard VolumeStorage.isValidVolumeName(request.name) else {
            throw VolumeError.invalidVolumeName("Invalid volume name '\(request.name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        // Check if volume already exists by trying to list and finding it
        let existingVolumes = try await store.list()
        if existingVolumes.contains(where: { $0.name == request.name }) {
            throw VolumeError.volumeAlreadyExists(request.name)
        }

        try createVolumeDirectory(for: request.name)
        try createVolumeImage(for: request.name)

        let volume = Volume(
            name: request.name,
            driver: request.driver,
            source: blockPath(for: request.name),
            labels: request.labels,
            options: request.driverOpts
        )

        try await store.create(volume)

        log.info("Created volume", metadata: ["name": "\(request.name)", "driver": "\(request.driver)"])
        return volume
    }

    public func delete(_ request: VolumeDeleteRequest) async throws {
        guard VolumeStorage.isValidVolumeName(request.name) else {
            throw VolumeError.invalidVolumeName("Invalid volume name '\(request.name)': only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }

        // Check if volume exists by trying to list and finding it
        let existingVolumes = try await store.list()
        guard existingVolumes.contains(where: { $0.name == request.name }) else {
            throw VolumeError.volumeNotFound(request.name)
        }

        try removeVolumeDirectory(for: request.name)
        try await store.delete(request.name)

        log.info("Deleted volume", metadata: ["name": "\(request.name)"])
    }

    public func list() async throws -> VolumeListResponse {
        let volumes = try await store.list()
        return VolumeListResponse(volumes: volumes)
    }

    public func inspect(_ name: String) async throws -> VolumeInspectResponse {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("Invalid volume name '\(name)': only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }

        let volumes = try await store.list()
        guard let volume = volumes.first(where: { $0.name == name }) else {
            throw VolumeError.volumeNotFound(name)
        }

        return VolumeInspectResponse(volume: volume)
    }
}
