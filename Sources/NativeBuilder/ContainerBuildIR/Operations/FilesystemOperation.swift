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

/// Represents filesystem operations (COPY, ADD, etc.).
///
/// Design rationale:
/// - Unified handling of all filesystem modifications
/// - Preserves source context (local, stage, URL)
/// - Supports advanced features like ownership and permissions
/// - Extensible for future filesystem operations
public struct FilesystemOperation: Operation, Hashable {
    public static let operationKind = OperationKind.filesystem
    public var operationKind: OperationKind { Self.operationKind }

    /// The filesystem action to perform
    public let action: FilesystemAction

    /// Source of the files
    public let source: FilesystemSource

    /// Destination path
    public let destination: String

    /// File metadata (ownership, permissions)
    public let fileMetadata: FileMetadata

    /// Copy options
    public let options: FilesystemOptions

    /// Operation metadata
    public let metadata: OperationMetadata

    public init(
        action: FilesystemAction,
        source: FilesystemSource,
        destination: String,
        fileMetadata: FileMetadata = FileMetadata(),
        options: FilesystemOptions = FilesystemOptions(),
        metadata: OperationMetadata = OperationMetadata()
    ) {
        self.action = action
        self.source = source
        self.destination = destination
        self.fileMetadata = fileMetadata
        self.options = options
        self.metadata = metadata
    }

    public func accept<V: OperationVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Filesystem Action

/// Type of filesystem action.
///
/// Design rationale:
/// - Covers all Dockerfile filesystem operations
/// - Extensible for future operations
/// - Clear semantics for each action
public enum FilesystemAction: String, Hashable, Sendable {
    /// Copy files (COPY instruction)
    case copy

    /// Add files with URL/tar support (ADD instruction)
    case add

    /// Remove files
    case remove

    /// Create directory
    case mkdir

    /// Create symlink
    case symlink

    /// Create hard link
    case hardlink
}

// MARK: - Filesystem Source

/// Source of filesystem content.
///
/// Design rationale:
/// - Type-safe source specifications
/// - Supports all Dockerfile source types
/// - Extensible for future sources
public enum FilesystemSource: Hashable, Sendable {
    /// Files from build context
    case context(ContextSource)

    /// Files from another stage
    case stage(StageReference, paths: [String])

    /// Files from an image
    case image(ImageReference, paths: [String])

    /// URL to download
    case url(URL)

    /// Git repository
    case git(GitSource)

    /// Inline content
    case inline(Data)

    /// Empty/scratch
    case scratch
}

/// Build context source.
public struct ContextSource: Hashable, Sendable {
    /// Name of the context
    public let name: String

    /// Paths relative to context root
    public let paths: [String]

    /// Include patterns (if empty, all files match)
    public let includes: [String]

    /// Exclude patterns
    public let excludes: [String]

    public init(name: String = "default", paths: [String], includes: [String] = [], excludes: [String] = []) {
        self.name = name
        self.paths = paths
        self.includes = includes
        self.excludes = excludes
    }
}

/// Git repository source.
public struct GitSource: Hashable, Sendable {
    public let repository: String
    public let reference: String?  // branch, tag, commit
    public let submodules: Bool

    public init(repository: String, reference: String? = nil, submodules: Bool = false) {
        self.repository = repository
        self.reference = reference
        self.submodules = submodules
    }
}

// MARK: - File Metadata

/// Metadata for created/modified files.
///
/// Design rationale:
/// - Captures all file attributes
/// - Platform-aware (Unix permissions vs Windows ACLs)
/// - Preserves source metadata by default
public struct FileMetadata: Hashable, Sendable {
    /// File ownership
    public let ownership: Ownership?

    /// File permissions (Unix mode)
    public let permissions: Permissions?

    /// Timestamps
    public let timestamps: Timestamps?

    /// Extended attributes
    public let xattrs: [String: Data]

    public init(
        ownership: Ownership? = nil,
        permissions: Permissions? = nil,
        timestamps: Timestamps? = nil,
        xattrs: [String: Data] = [:]
    ) {
        self.ownership = ownership
        self.permissions = permissions
        self.timestamps = timestamps
        self.xattrs = xattrs
    }
}

public enum OwnershipID: Hashable, Sendable {
    /// Numeric UID/GID
    case numeric(id: UInt32)

    /// Named user/group
    case named(id: String)
}

/// File ownership.
public struct Ownership: Hashable, Sendable {
    public let userID: OwnershipID?
    public let groupID: OwnershipID?

    public init(user: OwnershipID? = nil, group: OwnershipID? = nil) {
        self.userID = user
        self.groupID = group
    }
}

/// File permissions.
public enum Permissions: Hashable, Sendable {
    /// Unix mode (e.g., 0755)
    case mode(UInt32)

    /// Symbolic (e.g., "u+x")
    case symbolic(String)

    /// Preserve from source
    case preserve
}

/// File timestamps.
public struct Timestamps: Hashable, Sendable {
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?

    public init(created: Date? = nil, modified: Date? = nil, accessed: Date? = nil) {
        self.created = created
        self.modified = modified
        self.accessed = accessed
    }
}

// MARK: - Filesystem Options

/// Options for filesystem operations.
///
/// Design rationale:
/// - Controls operation behavior
/// - Platform-specific handling
/// - Performance optimizations
public struct FilesystemOptions: Hashable, Sendable {
    /// Follow symlinks in source
    public let followSymlinks: Bool

    /// Preserve timestamps
    public let preserveTimestamps: Bool

    /// Merge directories (don't replace)
    public let merge: Bool

    /// Create parent directories
    public let createParents: Bool

    /// For ADD: auto-extract archives
    public let extractArchives: Bool

    /// Copy strategy
    public let copyStrategy: CopyStrategy

    public init(
        followSymlinks: Bool = true,
        preserveTimestamps: Bool = false,
        merge: Bool = true,
        createParents: Bool = true,
        extractArchives: Bool = true,
        copyStrategy: CopyStrategy = .auto
    ) {
        self.followSymlinks = followSymlinks
        self.preserveTimestamps = preserveTimestamps
        self.merge = merge
        self.createParents = createParents
        self.extractArchives = extractArchives
        self.copyStrategy = copyStrategy
    }
}

/// Strategy for copying files.
public enum CopyStrategy: String, Hashable, Sendable {
    /// Automatically choose best method
    case auto

    /// Copy-on-write if available
    case cow

    /// Hard link if possible
    case hardlink

    /// Always full copy
    case copy
}

// MARK: - Codable

extension FilesystemOperation: Codable {}
extension FilesystemAction: Codable {}
extension FilesystemSource: Codable {}
extension ContextSource: Codable {}
extension GitSource: Codable {}
extension FileMetadata: Codable {}
extension OwnershipID: Codable {}
extension Ownership: Codable {}
extension Permissions: Codable {}
extension Timestamps: Codable {}
extension FilesystemOptions: Codable {}
extension CopyStrategy: Codable {}
