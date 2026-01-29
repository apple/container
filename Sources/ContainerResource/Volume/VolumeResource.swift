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

import Foundation

/// A named or anonymous volume that can be mounted in containers.
public struct VolumeResource: ManagedResource {
    // Associated error codes with the volume
    public typealias ErrorCode = VolumeErrorCode
    // Id of the volume.
    public var id: String { name }
    // Id of the resource.
    public var qualifiedId: String { "volume/\(name)" }
    // Name of the volume.
    public let name: String
    // Name of the volume.
    public let hexId: String
    // Driver used to create the volume.
    public let driver: String
    // Filesystem format of the volume.
    public let format: String
    // The mount point of the volume on the host.
    public let source: String
    // Timestamp when the volume was created.
    public let creationDate: Date
    // User-defined key/value metadata.
    public let labels: [String: String]
    // Driver-specific options.
    public let options: [String: String]
    // Size of the volume in bytes (optional).
    public let sizeInBytes: UInt64?

    public init(
        name: String?,
        driver: String = "local",
        format: String = "ext4",
        source: String,
        creationDate: Date,
        labels: [String: String] = [:],
        options: [String: String] = [:],
        sizeInBytes: UInt64? = nil
    ) {
        self.hexId = Self.generateId()
        self.name = name ?? self.hexId
        self.driver = driver
        self.format = format
        self.source = source
        self.creationDate = creationDate
        self.labels = labels
        self.options = options
        self.sizeInBytes = sizeInBytes
    }
    
    public static func nameValid(_ name: String) -> Bool {
        // TODO
        return true
    }
}

extension VolumeResource {
    /// Reserved label key for marking anonymous volumes
    public static let anonymousLabel = "com.apple.container.resource.anonymous"

    /// Whether this is an anonymous volume (detected via label)
    public var isAnonymous: Bool {
        labels[Self.anonymousLabel] != nil
    }
}

/// Error codes for volume operations.
public enum VolumeErrorCode: ManagedResourceErrorCode {
    case volumeNotFound
}

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
            return "volume '\(name)' not found"
        case .volumeAlreadyExists(let name):
            return "volume '\(name)' already exists"
        case .volumeInUse(let name):
            return "volume '\(name)' is currently in use and cannot be accessed by another container, or deleted"
        case .invalidVolumeName(let name):
            return "invalid volume name '\(name)'"
        case .driverNotSupported(let driver):
            return "volume driver '\(driver)' is not supported"
        case .storageError(let message):
            return "storage error: \(message)"
        }
    }
}

/// Volume storage management utilities.
public struct VolumeStorage {
    public static let volumeNamePattern = "^[A-Za-z0-9][A-Za-z0-9_.-]*$"
    public static let defaultVolumeSizeBytes: UInt64 = 512 * 1024 * 1024 * 1024  // 512GB

    public static func isValidVolumeName(_ name: String) -> Bool {
        guard name.count <= 255 else { return false }

        do {
            let regex = try Regex(volumeNamePattern)
            return (try? regex.wholeMatch(in: name)) != nil
        } catch {
            return false
        }
    }

    /// Generates an anonymous volume name with UUID format
    public static func generateAnonymousVolumeName() -> String {
        UUID().uuidString.lowercased()
    }
}
