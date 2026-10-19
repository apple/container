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

import ContainerPersistence
import ContainerResource
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
    private let resourceRoot: FilePath
    private let store: ContainerPersistence.FilesystemEntityStore<VolumeConfiguration>
    private let credentialStore: VolumeCredentialStore
    private let log: Logger
    private let lock = AsyncLock()
    private let containersService: ContainersService

    // Storage constants
    private static let entityFile = "entity.json"
    private static let blockFile = "volume.img"

    public init(
        resourceRoot: FilePath,
        containersService: ContainersService,
        log: Logger,
        credentialStore: VolumeCredentialStore = KeychainVolumeCredentialStore()
    ) async throws {
        try FileManager.default.createDirectory(atPath: resourceRoot.string, withIntermediateDirectories: true)
        self.resourceRoot = resourceRoot
        self.store = try FilesystemEntityStore<VolumeConfiguration>(path: resourceRoot, type: "volumes", log: log)
        self.credentialStore = credentialStore
        self.containersService = containersService
        self.log = log

        // Migrate configs stored with the old `createdAt` key to `creationDate`.
        // Deprecated: As of 1.0.0. Use ``creationDate`` instead of ``createdAt``.
        // Note: Will be removed in a later release.
        let configurations = try await store.list()
        for configuration in configurations {
            do {
                try await store.update(configuration)
            } catch {
                log.error(
                    "failed to migrate volume configuration",
                    metadata: [
                        "name": "\(configuration.name)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    public func create(
        name: String,
        driver: String = "local",
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:]
    ) async throws -> VolumeConfiguration {
        log.debug(
            "VolumesService: enter",
            metadata: [
                "func": "\(#function)",
                "name": "\(name)",
            ]
        )
        defer {
            log.debug(
                "VolumesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "name": "\(name)",
                ]
            )
        }

        return try await lock.withLock { _ in
            try await self._create(name: name, driver: driver, driverOpts: driverOpts, labels: labels)
        }
    }

    public func delete(name: String) async throws {
        log.debug(
            "VolumesService: enter",
            metadata: [
                "func": "\(#function)",
                "name": "\(name)",
            ]
        )
        defer {
            log.debug(
                "VolumesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "name": "\(name)",
                ]
            )
        }

        try await lock.withLock { _ in
            try await self._delete(name: name)
        }
    }

    public func list() async throws -> [VolumeConfiguration] {
        log.debug(
            "VolumesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            log.debug(
                "VolumesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        return try await store.list()
    }

    public func inspect(_ name: String) async throws -> VolumeConfiguration {
        log.debug(
            "VolumesService: enter",
            metadata: [
                "func": "\(#function)",
                "name": "\(name)",
            ]
        )
        defer {
            log.debug(
                "VolumesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "name": "\(name)",
                ]
            )
        }

        return try await lock.withLock { _ in
            try await self._inspect(name)
        }
    }

    /// Calculate disk usage for a single volume
    public func volumeDiskUsage(name: String) async throws -> UInt64 {
        log.debug(
            "VolumesService: enter",
            metadata: [
                "func": "\(#function)",
                "name": "\(name)",
            ]
        )
        defer {
            log.debug(
                "VolumesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "name": "\(name)",
                ]
            )
        }

        return try await self._volumeDiskUsage(name)
    }

    /// Calculate disk usage for volumes
    /// - Returns: Tuple of (total count, active count, total size, reclaimable size)
    public func calculateDiskUsage() async throws -> (Int, Int, UInt64, UInt64) {
        log.debug(
            "VolumesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            log.debug(
                "VolumesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        return try await lock.withLock { _ in
            let allVolumes = try await self.store.list()

            // Atomically get active volumes with container list
            return try await self.containersService.withContainerList(logMetadata: ["acquirer": "\(#function)"]) { containers in
                var inUseSet = Set<String>()

                // Find all mounted volumes
                for container in containers {
                    for mount in container.configuration.mounts {
                        if mount.isVolume, let volumeName = mount.volumeName {
                            inUseSet.insert(volumeName)
                        }
                    }
                }

                var totalSize: UInt64 = 0
                var reclaimableSize: UInt64 = 0

                // Calculate sizes
                for volume in allVolumes {
                    let volumePath = self.volumePath(for: volume.name)
                    let volumeSize = FileManager.default.allocatedSize(of: URL(fileURLWithPath: volumePath))
                    totalSize += volumeSize

                    if !inUseSet.contains(volume.name) {
                        reclaimableSize += volumeSize
                    }
                }

                return (allVolumes.count, inUseSet.count, totalSize, reclaimableSize)
            }
        }
    }

    private func parseSize(_ sizeString: String) throws -> UInt64 {
        let measurement = try Measurement.parse(parsing: sizeString)
        let bytes = measurement.converted(to: .bytes).value

        // Validate minimum size
        let minSize: UInt64 = 1.mib()  // 1mib minimum

        let sizeInBytes = UInt64(bytes)

        guard sizeInBytes >= minSize else {
            throw VolumeError.storageError("volume size too small: minimum 1MiB")
        }

        return sizeInBytes
    }

    // FIXME: These don't guarantee that name doesn't have component separators.
    private nonisolated func volumePath(for name: String) -> String {
        resourceRoot.appending(name).string
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

    static func parseJournalConfig(_ value: String) throws -> EXT4.JournalConfig {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard let modeSubstring = parts.first else {
            throw VolumeError.storageError("invalid journal configuration: expected 'mode' or 'mode:size'")
        }
        let modeString = String(modeSubstring)
        let mode: EXT4.JournalConfig.JournalMode
        switch modeString {
        case "writeback": mode = .writeback
        case "ordered": mode = .ordered
        case "journal": mode = .journal
        default:
            throw VolumeError.storageError("invalid journal mode '\(modeString)': must be writeback, ordered, or journal")
        }
        let size: UInt64? =
            try parts.count > 1
            ? UInt64(Measurement.parse(parsing: String(parts[1])).converted(to: .bytes).value)
            : nil
        return EXT4.JournalConfig(size: size, defaultMode: mode)
    }

    /// Validates the driver options of an `smb` or `nfs` volume.
    ///
    /// - Parameters:
    ///   - driverOpts: The options passed with `--opt key=value`.
    ///   - driver: The driver name, used in error messages.
    ///   - shareExample: An example `share` value for the driver, used in error messages.
    /// - Returns: The non-empty `share` option.
    /// - Throws: `VolumeError.invalidOption` if `share` is missing or empty, if `size` is present,
    ///   or if the share or any option is not syntactically valid.
    static func validateNetworkDriverOptions(_ driverOpts: [String: String], driver: String, shareExample: String) throws -> String {
        guard let share = driverOpts[MountOptionValidator.shareKey], !share.isEmpty else {
            throw VolumeError.invalidOption("\(driver) driver requires --opt share=\(shareExample)")
        }
        if driverOpts["size"] != nil {
            throw VolumeError.invalidOption("size option is not supported for \(driver) driver")
        }
        do {
            // Checks the share as a mount source and the remaining options as mount options.
            try MountOptionValidator.validate(driverOpts)
        } catch let violation as MountOptionValidator.Violation {
            throw VolumeError.invalidOption(violation.description)
        }
        return share
    }

    private func createVolumeImage(for name: String, sizeInBytes: UInt64 = VolumeStorage.defaultVolumeSizeBytes, journal: EXT4.JournalConfig? = nil) throws {
        let blockPath = blockPath(for: name)

        // Use the containerization library's EXT4 formatter
        let formatter = try EXT4.Formatter(
            FilePath(blockPath),
            blockSize: 4096,
            minDiskSize: sizeInBytes,
            journal: journal
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
    ) async throws -> VolumeConfiguration {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        // Check if volume already exists by trying to list and finding it
        let existingVolumes = try await store.list()
        if existingVolumes.contains(where: { $0.name == name }) {
            throw VolumeError.volumeAlreadyExists(name)
        }

        let volume: VolumeConfiguration
        var credential: VolumeCredential?
        switch driver {
        case "smb":
            let share = try Self.validateNetworkDriverOptions(driverOpts, driver: driver, shareExample: "//server/share")
            var options = driverOpts
            credential = try Self.extractSMBCredential(from: &options)
            volume = VolumeConfiguration(
                name: name,
                driver: "smb",
                format: "cifs",
                source: share,
                labels: labels,
                options: options,
                sizeInBytes: nil
            )
        case "nfs":
            let share = try Self.validateNetworkDriverOptions(driverOpts, driver: driver, shareExample: "server:/export/path")
            // NFS has no password option, so a secret here could only end up stored in plain text.
            if let key = driverOpts.keys.sorted().first(where: MountOptionValidator.secretKeys.contains) {
                throw VolumeError.invalidOption("nfs driver does not support option '\(key)'")
            }
            volume = VolumeConfiguration(
                name: name,
                driver: "nfs",
                format: "nfs",
                source: share,
                labels: labels,
                options: driverOpts,
                sizeInBytes: nil
            )
        case "local":
            try createVolumeDirectory(for: name)

            // Parse size from driver options, or use the system default value
            let sizeInBytes: UInt64
            if let sizeString = driverOpts["size"] {
                sizeInBytes = try parseSize(sizeString)
            } else {
                sizeInBytes = VolumeStorage.defaultVolumeSizeBytes
            }

            let journalConfig = try driverOpts["journal"].map { try Self.parseJournalConfig($0) }

            try createVolumeImage(for: name, sizeInBytes: sizeInBytes, journal: journalConfig)

            volume = VolumeConfiguration(
                name: name,
                driver: "local",
                format: "ext4",
                source: blockPath(for: name),
                labels: labels,
                options: driverOpts,
                sizeInBytes: sizeInBytes
            )
        default:
            throw VolumeError.driverNotSupported(driver)
        }

        // Store the secret before the volume so a volume never exists without its credential.
        // If the volume cannot then be stored, remove the credential again.
        if let credential {
            do {
                try credentialStore.save(volume: name, credential: credential)
            } catch {
                throw VolumeError.storageError("failed to store the password for volume '\(name)' in the keychain: \(error)")
            }
        }
        do {
            try await store.create(volume)
        } catch {
            if credential != nil {
                try? credentialStore.delete(volume: name)
            }
            throw error
        }

        log.info(
            "created volume",
            metadata: [
                "name": "\(name)",
                "driver": "\(driver)",
                "isAnonymous": "\(volume.isAnonymous)",
                "hasCredential": "\(credential != nil)",
            ])
        return volume
    }

    /// Removes the SMB password from `options` and returns it with its username as a credential.
    ///
    /// Only `password` is accepted as the key for the secret. The other keys that cifs treats as a
    /// password or a credentials file are rejected so a secret cannot slip into the stored options
    /// under another name.
    ///
    /// - Returns: The credential, or nil if no password was given.
    /// - Throws: `VolumeError.invalidOption` if a password is given without a username, or if a
    ///   secret key other than `password` is present.
    static func extractSMBCredential(from options: inout [String: String]) throws -> VolumeCredential? {
        let otherSecretKeys = MountOptionValidator.secretKeys.subtracting([MountOptionValidator.passwordKey])
        if let key = options.keys.sorted().first(where: otherSecretKeys.contains) {
            throw VolumeError.invalidOption("smb option '\(key)' is not supported; use --opt \(MountOptionValidator.passwordKey)=<password>")
        }
        guard let password = options.removeValue(forKey: MountOptionValidator.passwordKey) else {
            return nil
        }
        guard let username = options["username"], !username.isEmpty else {
            throw VolumeError.invalidOption("smb driver requires --opt username=<user> when a password is given")
        }
        return VolumeCredential(username: username, password: password)
    }

    private func _delete(name: String) async throws {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        // Check if volume exists by trying to list and finding it
        let existingVolumes = try await store.list()
        guard let volume = existingVolumes.first(where: { $0.name == name }) else {
            throw VolumeError.volumeNotFound(name)
        }

        // Check if volume is in use by any container atomically
        try await containersService.withContainerList(logMetadata: ["acquirer": "\(#function)", "name": "\(name)"]) { containers in
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

        // The credential is removed last so a failure to delete the volume never leaves a volume
        // without its credential. A failure here is logged rather than thrown, since the volume is
        // already gone and the next create under the same name replaces the item anyway.
        if volume.driver == "smb" {
            do {
                try credentialStore.delete(volume: name)
            } catch {
                log.warning(
                    "failed to remove the credential for a deleted volume from the keychain",
                    metadata: ["name": "\(name)", "error": "\(error)"]
                )
            }
        }

        log.info("deleted volume", metadata: ["name": "\(name)"])
    }

    private func _inspect(_ name: String) async throws -> VolumeConfiguration {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        let volumes = try await store.list()
        guard let volume = volumes.first(where: { $0.name == name }) else {
            throw VolumeError.volumeNotFound(name)
        }

        return volume
    }

    private func _volumeDiskUsage(_ name: String) async throws -> UInt64 {
        guard VolumeStorage.isValidVolumeName(name) else {
            throw VolumeError.invalidVolumeName("invalid volume name '\(name)': must match \(VolumeStorage.volumeNamePattern)")
        }

        let volumePath = self.volumePath(for: name)
        return FileManager.default.allocatedSize(of: URL(fileURLWithPath: volumePath))
    }
}
