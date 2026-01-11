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
public struct Volume: Sendable, Codable, Equatable, Identifiable {
    // id of the volume.
    public var id: String { name }
    // Name of the volume.
    public var name: String
    // Driver used to create the volume.
    public var driver: String
    // Filesystem format of the volume.
    public var format: String
    // The mount point of the volume on the host.
    public var source: String
    // Timestamp when the volume was created.
    public var createdAt: Date
    // User-defined key/value metadata.
    public var labels: [String: String]
    // Driver-specific options.
    public var options: [String: String]
    // Size of the volume in bytes (optional).
    public var sizeInBytes: UInt64?

    public init(
        name: String,
        driver: String = "local",
        format: String = "ext4",
        source: String,
        createdAt: Date = Date(),
        labels: [String: String] = [:],
        options: [String: String] = [:],
        sizeInBytes: UInt64? = nil
    ) {
        self.name = name
        self.driver = driver
        self.format = format
        self.source = source
        self.createdAt = createdAt
        self.labels = labels
        self.options = options
        self.sizeInBytes = sizeInBytes
    }
}

extension Volume {
    /// Reserved label key for marking anonymous volumes
    public static let anonymousLabel = "com.apple.container.resource.anonymous"

    /// Whether this is an anonymous volume (detected via label)
    public var isAnonymous: Bool {
        labels[Self.anonymousLabel] != nil
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
