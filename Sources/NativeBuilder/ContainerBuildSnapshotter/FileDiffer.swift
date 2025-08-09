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

/// POSIX file permission bits
public struct FilePermissions: Equatable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
}

/// Result of file-level comparison combining metadata and optional content checks
public enum FileDiffResult: Equatable {
    case noChange
    case metadataOnly
    case contentChanged
    case typeChanged
    case symlinkTargetChanged
}

/// Orchestrates metadata comparison and optional content hashing to classify file-level changes.
/// - Uses FileMetadataDiffer for attribute-level comparison
/// - Uses FileContentDiffer to stream-hash regular files when metadata suggests it's required
public struct FileDiffer: Sendable {

    private let contentDiffer: FileContentDiffer
    private let metadataDiffer: FileMetadataDiffer

    public init(
        contentDiffer: FileContentDiffer = FileContentDiffer(),
        metadataDiffer: FileMetadataDiffer = FileMetadataDiffer()
    ) {
        self.contentDiffer = contentDiffer
        self.metadataDiffer = metadataDiffer
    }

    /// Diff two filesystem nodes.
    /// - Parameters:
    ///   - oldAttrs: Normalized attributes for the base node
    ///   - newAttrs: Normalized attributes for the target node
    ///   - oldURL: URL of base node for content hashing when needed
    ///   - newURL: URL of target node for content hashing when needed
    ///   - options: Normalization options used for interpretation
    /// - Returns: FileDiffResult describing the kind of change
    public func diff(
        oldAttrs: NormalizedFileAttributes,
        newAttrs: NormalizedFileAttributes,
        oldURL: URL,
        newURL: URL,
        options: InspectorOptions
    ) throws -> FileDiffResult {
        // First, compare metadata structurally
        let meta = metadataDiffer.diff(old: oldAttrs, new: newAttrs, options: options)

        // Short-circuit for type and symlink target changes
        switch meta {
        case .typeChanged:
            return .typeChanged
        case .symlinkTargetChanged:
            return .symlinkTargetChanged
        case .noChange, .metadataOnly:
            break
        }

        // Decide on hashing only for regular files
        if oldAttrs.type == .regular && newAttrs.type == .regular {
            let oldSize = oldAttrs.size ?? -1
            let newSize = newAttrs.size ?? -1

            // If sizes differ, content changed without hashing
            if oldSize != newSize {
                return .contentChanged
            }

            // Sizes are equal - we need to hash to be sure about content changes
            // We can't rely solely on mtime as it might be the same for quickly created files
            let r = try contentDiffer.diff(oldURL: oldURL, newURL: newURL)

            // If content changed, that takes precedence
            if r == .contentChanged {
                return .contentChanged
            }

            // Content is the same, return metadata result
            return meta == .metadataOnly ? .metadataOnly : .noChange
        }

        // Non-regular nodes: content hashing not applicable; propagate metadata decision
        return meta == .metadataOnly ? .metadataOnly : .noChange
    }

    /// Async convenience that reads attributes using a FileAttributeInspector, then delegates to the core diff.
    /// - Returns: Tuple of (result, newAttrs) so callers can project fields for output without re-inspecting.
    public func diff(
        oldURL: URL,
        newURL: URL,
        options: InspectorOptions,
        inspector: any FileAttributeInspector = DefaultFileAttributeInspector()
    ) async throws -> (result: FileDiffResult, newAttrs: NormalizedFileAttributes) {
        let oa = try await inspector.inspect(url: oldURL, options: options)
        let na = try await inspector.inspect(url: newURL, options: options)
        let r = try diff(
            oldAttrs: oa,
            newAttrs: na,
            oldURL: oldURL,
            newURL: newURL,
            options: options
        )
        return (r, na)
    }
}

// Bridge from file-level result to protocol-level modification kind.
extension Diff.Modified.Kind {
    /// Bridge from FileDiffResult to a modification kind. Returns nil for `.noChange`.
    public init?(_ r: FileDiffResult) {
        switch r {
        case .noChange:
            return nil
        case .metadataOnly:
            self = .metadataOnly
        case .contentChanged:
            self = .contentChanged
        case .typeChanged:
            self = .typeChanged
        case .symlinkTargetChanged:
            self = .symlinkTargetChanged
        }
    }
}
