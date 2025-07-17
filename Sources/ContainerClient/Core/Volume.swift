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

import Foundation

/// A named volume that can be mounted in containers.
public struct Volume: Sendable, Codable, Equatable {
    // Name of the volume.
    public var name: String
    // Driver used to create the volume.
    public var driver: String
    // The mount point of the volume on the host.
    public var mountpoint: String
    // Timestamp when the volume was created.
    public var createdAt: Date
    // User-defined key/value metadata.
    public var labels: [String: String]
    // Driver-specific options.
    public var options: [String: String]
    // Size of the volume in bytes (optional).
    public var sizeInBytes: UInt64?
    // Usage data for the volume.
    public var usageData: VolumeUsageData?

    public init(
        name: String,
        driver: String = "local",
        mountpoint: String,
        createdAt: Date = Date(),
        labels: [String: String] = [:],
        options: [String: String] = [:],
        sizeInBytes: UInt64? = nil,
        usageData: VolumeUsageData? = nil
    ) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.createdAt = createdAt
        self.labels = labels
        self.options = options
        self.sizeInBytes = sizeInBytes
        self.usageData = usageData
    }
}

/// Usage information for a volume.
public struct VolumeUsageData: Sendable, Codable, Equatable {
    // Size of the volume in bytes.
    public var sizeInBytes: Int64
    // Number of containers currently using this volume.
    public var refCount: Int64

    public init(sizeInBytes: Int64, refCount: Int64) {
        self.sizeInBytes = sizeInBytes
        self.refCount = refCount
    }
}

/// Request to create a new volume.
public struct VolumeCreateRequest: Sendable, Codable {
    // Name of the volume to create.
    public var name: String
    // Driver to use for the volume.
    public var driver: String
    // Driver-specific options.
    public var driverOpts: [String: String]
    // User-defined labels.
    public var labels: [String: String]

    public init(
        name: String,
        driver: String = "local",
        driverOpts: [String: String] = [:],
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.driver = driver
        self.driverOpts = driverOpts
        self.labels = labels
    }
}

/// Request to delete a volume.
public struct VolumeDeleteRequest: Sendable, Codable {
    // Name of the volume to delete.
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// Response containing a list of volumes.
public struct VolumeListResponse: Sendable, Codable {
    // List of volumes.
    public var volumes: [Volume]
    // Warnings from the operation.
    public var warnings: [String]

    public init(volumes: [Volume], warnings: [String] = []) {
        self.volumes = volumes
        self.warnings = warnings
    }
}

/// Response containing volume details.
public struct VolumeInspectResponse: Sendable, Codable {
    // The volume details.
    public var volume: Volume

    public init(volume: Volume) {
        self.volume = volume
    }
}

/// Error types for volume operations.
public enum VolumeError: Error, LocalizedError {
    case volumeNotFound(String)
    case volumeAlreadyExists(String)
    case volumeInUse(String)
    case invalidVolumeName(String)
    case driverNotSupported(String)
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .volumeNotFound(let name):
            return "Volume '\(name)' not found"
        case .volumeAlreadyExists(let name):
            return "Volume '\(name)' already exists"
        case .volumeInUse(let name):
            return "Volume '\(name)' is in use and cannot be removed"
        case .invalidVolumeName(let name):
            return "Invalid volume name '\(name)'"
        case .driverNotSupported(let driver):
            return "Volume driver '\(driver)' is not supported"
        case .storageError(let message):
            return "Storage error: \(message)"
        }
    }
}

/// Volume storage management utilities.
public struct VolumeStorage {
    public static let volumesDirectory: String = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        .appendingPathComponent("com.apple.container")
        .appendingPathComponent("volumes")
        .path
    }()

    public static let entityFile = "entity.json"
    public static let blockFile = "volume.img"

    public static func volumePath(for name: String) -> String {
        "\(volumesDirectory)/\(name)"
    }

    public static func entityPath(for name: String) -> String {
        "\(volumePath(for: name))/\(entityFile)"
    }

    public static func blockPath(for name: String) -> String {
        "\(volumePath(for: name))/\(blockFile)"
    }

    public static func isValidVolumeName(_ name: String) -> Bool {
        // Volume names must be 1-255 characters and contain only a-zA-Z0-9, periods, dashes, and underscores
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !name.isEmpty && name.count <= 255 && name.rangeOfCharacter(from: allowedCharacters.inverted) == nil && !name.hasPrefix(".") && !name.hasSuffix(".")
    }

    // Creates the volumes directory if it doesn't exist.
    public static func ensureVolumesDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: volumesDirectory) {
            try fm.createDirectory(atPath: volumesDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // Creates a volume directory structure.
    public static func createVolumeDirectory(for name: String) throws {
        let volumePath = volumePath(for: name)
        let fm = FileManager.default

        try fm.createDirectory(atPath: volumePath, withIntermediateDirectories: true, attributes: nil)
    }

    // Creates an ext4 sparse image file for the volume.
    public static func createVolumeImage(for name: String, sizeInBytes: UInt64 = 1024 * 1024 * 1024) throws {
        let blockPath = blockPath(for: name)
        let fm = FileManager.default

        // Create sparse file
        fm.createFile(atPath: blockPath, contents: nil, attributes: nil)

        // Truncate to desired size to create sparse file
        let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: blockPath))
        defer { try? fileHandle.close() }
        try fileHandle.truncate(atOffset: sizeInBytes)
    }

    // Removes a volume directory and all its contents.
    public static func removeVolumeDirectory(for name: String) throws {
        let volumePath = volumePath(for: name)
        let fm = FileManager.default

        if fm.fileExists(atPath: volumePath) {
            try fm.removeItem(atPath: volumePath)
        }
    }
}
