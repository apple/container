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
import Crypto
import Foundation

/// A canonical, Merkle-based diff key for filesystem layer reuse.
///
/// The key is computed deterministically from the ordered set of filesystem
/// changes between (base,target). It incorporates normalized metadata and, where
/// applicable, per-entry content digests. The final key is namespaced and
/// versioned for forward compatibility.
///
/// Encoding: single value string "sha256:<hex>" for easy persistence/interchange.
public struct DiffKey: Sendable, Hashable, Codable {
    // Stored as "sha256:<hex>"
    private let value: String

    /// Return the canonical string form, e.g. "sha256:<hex>".
    public var stringValue: String { value }

    /// Return the raw hex portion (without the "sha256:" prefix).
    public var rawHex: String {
        if let idx = value.firstIndex(of: ":") {
            return String(value[value.index(after: idx)...])
        }
        return value
    }

    public init(parsing string: String) throws {
        // Only accept canonical "sha256:<hex>" form to avoid ambiguity.
        guard string.hasPrefix("sha256:") else {
            throw DiffKeyError.invalidFormat("unsupported format, expected sha256:<hex>")
        }
        // Basic sanity check on hex length (64 for sha256)
        let hex = String(string.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw DiffKeyError.invalidFormat("invalid sha256 hex")
        }
        self.value = string
    }

    public init(bytes: Data) {
        self.value = "sha256:\(Self.hex(bytes))"
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        try self.init(parsing: s)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    // MARK: - Compute

    /// Compute a canonical DiffKey for (base,target) by walking the filesystem
    /// and constructing a Merkle root over canonicalized diff entries.
    ///
    /// - Parameters:
    ///   - baseDigest: Optional digest of the base snapshot; baked into the root
    ///                 as a domain separator to couple reuse semantics to lineage.
    ///   - baseMount:  Optional prepared mountpoint of the base; if nil, treated as scratch.
    ///   - targetMount: Prepared mountpoint of the target snapshot.
    ///   - hasher:     Content hasher for regular file content.
    ///   - inspectorOptions: Options for attribute normalization (xattrs, timestamps).
    public static func compute(
        baseDigest: ContainerBuildIR.Digest?,
        baseMount: URL?,
        targetMount: URL,
        hasher: any ContentHasher = SHA256ContentHasher(),
        inspectorOptions: InspectorOptions = InspectorOptions()
    ) async throws -> DiffKey {
        // Build a DirectoryDiffer with the provided hasher/options to ensure
        // metadata normalization matches the differ used for tar generation.
        let directoryDiffer = DirectoryDiffer(
            inspector: DefaultFileAttributeInspector(),
            fileDiffer: FileDiffer(
                contentDiffer: FileContentDiffer(hasher: hasher),
                metadataDiffer: FileMetadataDiffer()
            ),
            options: inspectorOptions
        )

        let changes = try await directoryDiffer.diff(base: baseMount, target: targetMount)

        // Canonicalize each change into a stable line, then compute leaf hashes.
        var lines: [String] = []
        lines.reserveCapacity(changes.count)

        for change in changes {
            switch change {
            case .added(let a):
                let node = Self.nodeString(a.node)
                let perms = a.permissions?.rawValue ?? 0
                let uid = a.uid.map(String.init) ?? "-"
                let gid = a.gid.map(String.init) ?? "-"
                let lnk = a.linkTarget ?? "-"
                let xh = Self.xattrsHashHex(a.xattrs)
                let ch = try await Self.contentHashHexIfNeeded(
                    node: a.node,
                    kind: .contentChanged,  // additions imply content surfaced
                    at: targetMount.appendingPathComponent(a.path),
                    hasher: hasher
                )
                lines.append("A|\(a.path)|\(node)|\(perms)|\(uid)|\(gid)|\(lnk)|xh:\(xh)|ch:\(ch ?? "-")")

            case .modified(let m):
                let node = Self.nodeString(m.node)
                let kind = Self.kindString(m.kind)
                let perms = m.permissions?.rawValue ?? 0
                let uid = m.uid.map(String.init) ?? "-"
                let gid = m.gid.map(String.init) ?? "-"
                let lnk = m.linkTarget ?? "-"
                let xh = Self.xattrsHashHex(m.xattrs)
                let ch = try await Self.contentHashHexIfNeeded(
                    node: m.node,
                    kind: m.kind,
                    at: targetMount.appendingPathComponent(m.path),
                    hasher: hasher
                )
                lines.append("M|\(m.path)|\(kind)|\(node)|\(perms)|\(uid)|\(gid)|\(lnk)|xh:\(xh)|ch:\(ch ?? "-")")

            case .deleted(let path):
                lines.append("D|\(path)")
            }
        }

        // Sort canonically by path-first ordering to remove traversal nondeterminism.
        lines.sort { (lhs, rhs) in
            // Both formats start with "<A/M/D>|<path>|..."
            // Compare by path slice primarily; fallback to whole string for total order.
            let lp = Self.pathSlice(lhs)
            let rp = Self.pathSlice(rhs)
            if lp != rp { return lp < rp }
            return lhs < rhs
        }

        // Compute leaf hashes
        var leaves: [Data] = []
        leaves.reserveCapacity(lines.count)
        for line in lines {
            var h = SHA256()
            if let data = line.data(using: .utf8) {
                h.update(data: data)
            }
            leaves.append(Data(h.finalize()))
        }

        let root = Self.merkleRoot(leaves)

        // Domain separation and base coupling
        var final = SHA256()
        let baseTag = baseDigest?.stringValue ?? "scratch"
        let prefix = "diffkey:v1|\(baseTag)|"
        if let prefixData = prefix.data(using: String.Encoding.utf8) {
            final.update(data: prefixData)
        }
        final.update(data: root)
        let digest = Data(final.finalize())

        return DiffKey(bytes: digest)
    }

    // MARK: - Internals

    private static func nodeString(_ node: Diff.Modified.Node) -> String {
        switch node {
        case .regular: return "reg"
        case .directory: return "dir"
        case .symlink: return "sym"
        case .device: return "dev"
        case .fifo: return "fifo"
        case .socket: return "sock"
        }
    }

    private static func kindString(_ kind: Diff.Modified.Kind) -> String {
        switch kind {
        case .metadataOnly: return "meta"
        case .contentChanged: return "content"
        case .typeChanged: return "type"
        case .symlinkTargetChanged: return "symlink"
        }
    }

    private static func xattrsHashHex(_ xattrs: [String: Data]?) -> String {
        guard let xattrs, !xattrs.isEmpty else { return "-" }
        let keys = xattrs.keys.sorted()
        var h = SHA256()
        for k in keys {
            // Serialize as "key\nbase64(value)\n"
            if let kd = k.data(using: .utf8) {
                h.update(data: kd)
            }
            h.update(data: Data([0x0A]))  // \n
            if let v = xattrs[k] {
                let b64 = v.base64EncodedString()
                if let vd = b64.data(using: .utf8) {
                    h.update(data: vd)
                }
            }
            h.update(data: Data([0x0A]))  // \n
        }
        return hex(Data(h.finalize()))
    }

    private static func contentHashHexIfNeeded(
        node: Diff.Modified.Node,
        kind: Diff.Modified.Kind,
        at url: URL,
        hasher: any ContentHasher
    ) async throws -> String? {
        // Only for regular files when content changes or when added.
        guard node == .regular else { return nil }
        switch kind {
        // additions passed kind: .contentChanged
        case .contentChanged, .metadataOnly, .typeChanged, .symlinkTargetChanged:
            // For modified entries, we only want hashing when kind == contentChanged.
            // For metadata-only/type/symlinkTarget changes, do not hash.
            break
        }
        if kind != .contentChanged {
            return nil
        }
        // Hash may throw if file disappeared; treat as no content hash if not present
        if !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }
        let d = try hasher.hash(fileURL: url)
        return hex(d)
    }

    private static func pathSlice(_ line: String) -> String {
        // "<op>|<path>|..."
        let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count >= 2 { return String(parts[1]) }
        return line
    }

    private static func merkleRoot(_ leaves: [Data]) -> Data {
        switch leaves.count {
        case 0:
            // Empty diff still produces a deterministic key
            var h = SHA256()
            h.update(data: Data("empty".utf8))
            return Data(h.finalize())
        case 1:
            return leaves[0]
        default:
            var level = leaves
            while level.count > 1 {
                var next: [Data] = []
                next.reserveCapacity((level.count + 1) / 2)
                var i = 0
                while i < level.count {
                    let left = level[i]
                    let right = (i + 1 < level.count) ? level[i + 1] : level[i]  // duplicate last if odd
                    var h = SHA256()
                    h.update(data: left)
                    h.update(data: right)
                    next.append(Data(h.finalize()))
                    i += 2
                }
                level = next
            }
            return level[0]
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DiffKeyError: Error, CustomStringConvertible {
    case invalidFormat(String)

    public var description: String {
        switch self {
        case .invalidFormat(let m): return "DiffKey invalid format: \(m)"
        }
    }
}
