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

import ContainerBuildIR
import Foundation

/// A filesystem snapshot representing state at a point in the build.
public struct Snapshot: Sendable, Codable {
    /// Unique identifier for this snapshot.
    public let id: UUID

    /// The digest of the snapshot content.
    public let digest: Digest

    /// Size of the snapshot in bytes.
    public let size: Int64

    /// Parent snapshot (if any).
    public let parent: UUID?

    /// Timestamp when the snapshot was created.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        digest: Digest,
        size: Int64,
        parent: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.digest = digest
        self.size = size
        self.parent = parent
        self.createdAt = createdAt
    }
}

/// Describes filesystem changes made by an operation.
public struct FilesystemChanges: Sendable, Codable {
    /// Files that were added.
    public let added: Set<String>

    /// Files that were modified.
    public let modified: Set<String>

    /// Files that were deleted.
    public let deleted: Set<String>

    /// Files that were removed (alias for deleted).
    public var removed: Set<String> { deleted }

    /// Total size change in bytes.
    public let sizeChange: Int64

    public init(
        added: Set<String> = [],
        modified: Set<String> = [],
        deleted: Set<String> = [],
        sizeChange: Int64 = 0
    ) {
        self.added = added
        self.modified = modified
        self.deleted = deleted
        self.sizeChange = sizeChange
    }

    /// Empty filesystem changes.
    public static let empty = FilesystemChanges()

    /// Check if any changes were made.
    public var hasChanges: Bool {
        !added.isEmpty || !modified.isEmpty || !deleted.isEmpty
    }
}
