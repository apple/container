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
import ContainerizationOCI
import Foundation

/// A protocol for computing and storing filesystem diffs
///
/// The Differ is responsible for:
/// 1. Computing the delta between two filesystem states
/// 2. Serializing that delta into an OCI-compliant layer format
/// 3. Storing the layer to a content store
/// 4. Returning a descriptor that can be used in OCI manifests
public protocol Differ: Sendable {
    /// The content store where diffs will be stored
    var contentStore: any ContentStore { get }

    /// Compute the difference between two snapshots and store it.
    ///
    /// This method performs the complete diff workflow:
    /// 1. Computes filesystem changes between base and target
    /// 2. Creates a tar archive of those changes
    /// 3. Applies the specified compression format
    /// 4. Stores the result to the content store
    /// 5. Returns a descriptor suitable for OCI manifests
    ///
    /// - Parameters:
    ///   - base: The base snapshot (nil for initial/scratch layers)
    ///   - target: The target snapshot to diff against base
    ///   - format: The compression format to use for the layer
    /// - Returns: A Descriptor containing the descriptor and statistics
    /// - Throws: If diff computation or storage fails
    func diff(
        base: Snapshot?,
        target: Snapshot
    ) async throws -> Descriptor

    /// Apply a stored diff to a base snapshot to produce a target.
    ///
    /// This is the inverse operation of computeAndStore, used when:
    /// - Materializing snapshots from cached layers
    /// - Applying patches during incremental builds
    /// - Validating diff correctness
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor of the stored diff
    ///   - base: The base snapshot to apply the diff to (nil for scratch)
    /// - Returns: The resulting snapshot after applying the diff
    /// - Throws: If the diff cannot be applied
    func apply(
        descriptor: Descriptor,
        to base: Snapshot?
    ) async throws -> Snapshot
}

/// Diff represents a filesystem diff entry.
///
/// - Additions and deletions only need the path previously, but we now surface
///   normalized attributes for both additions and modifications to avoid re-reading
///   from the OS during archive creation.
public enum Diff: Sendable, Equatable {
    /// Details for an addition entry with surfaced attributes.
    public struct Added: Sendable, Equatable {
        public let path: BinaryPath
        public let node: Modified.Node
        public let permissions: FilePermissions?
        public let size: Int64?
        public let modificationTime: Date?
        public let linkTarget: BinaryPath?
        public let uid: UInt32?
        public let gid: UInt32?
        public let xattrs: [String: Data]?
        public let devMajor: UInt32?
        public let devMinor: UInt32?
        public let nlink: UInt64?

        public init(
            path: BinaryPath,
            node: Modified.Node,
            permissions: FilePermissions?,
            size: Int64?,
            modificationTime: Date?,
            linkTarget: BinaryPath?,
            uid: UInt32?,
            gid: UInt32?,
            xattrs: [String: Data]?,
            devMajor: UInt32?,
            devMinor: UInt32?,
            nlink: UInt64?
        ) {
            self.path = path
            self.node = node
            self.permissions = permissions
            self.size = size
            self.modificationTime = modificationTime
            self.linkTarget = linkTarget
            self.uid = uid
            self.gid = gid
            self.xattrs = xattrs
            self.devMajor = devMajor
            self.devMinor = devMinor
            self.nlink = nlink
        }
    }

    /// Details for a modification entry.
    public struct Modified: Sendable, Equatable {
        /// The kind of modification detected. Derived from FileDiffResult.
        public enum Kind: Sendable, Equatable {
            case metadataOnly
            case contentChanged
            case typeChanged
            case symlinkTargetChanged
        }

        /// Kind of filesystem node (target state).
        public enum Node: Sendable, Equatable {
            case regular
            case directory
            case symlink
            case device
            case fifo
            case socket
        }

        public let path: BinaryPath
        public let kind: Kind
        public let node: Node
        public let permissions: FilePermissions?
        public let size: Int64?
        public let modificationTime: Date?
        public let linkTarget: BinaryPath?
        public let uid: UInt32?
        public let gid: UInt32?
        public let xattrs: [String: Data]?
        public let devMajor: UInt32?
        public let devMinor: UInt32?
        public let nlink: UInt64?

        public init(
            path: BinaryPath,
            kind: Kind,
            node: Node,
            permissions: FilePermissions?,
            size: Int64?,
            modificationTime: Date?,
            linkTarget: BinaryPath?,
            uid: UInt32?,
            gid: UInt32?,
            xattrs: [String: Data]?,
            devMajor: UInt32?,
            devMinor: UInt32?,
            nlink: UInt64?
        ) {
            self.path = path
            self.kind = kind
            self.node = node
            self.permissions = permissions
            self.size = size
            self.modificationTime = modificationTime
            self.linkTarget = linkTarget
            self.uid = uid
            self.gid = gid
            self.xattrs = xattrs
            self.devMajor = devMajor
            self.devMinor = devMinor
            self.nlink = nlink
        }
    }

    case added(Added)
    case modified(Modified)
    case deleted(path: BinaryPath)
}

/// POSIX file permission bits
public struct FilePermissions: Equatable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
}

public protocol ContentHasher: Sendable {
    func hash(fileURL: URL) throws -> Data
}
