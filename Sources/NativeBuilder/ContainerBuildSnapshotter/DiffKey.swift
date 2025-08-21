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
    // MARK: - Constants

    /// Protocol prefix for DiffKey string representation
    private static let protocolPrefix = "sha256:"

    /// Expected hex string length for SHA256
    private static let sha256HexLength = 64

    /// Version byte for record encoding
    private static let recordVersion: UInt8 = 0x01

    /// Record type tags
    private static let addedTag: UInt8 = 0x41  // 'A'
    private static let modifiedTag: UInt8 = 0x4D  // 'M'
    private static let deletedTag: UInt8 = 0x44  // 'D'

    /// Merkle tree node type tags
    private static let leafTag: UInt8 = 0x4C  // 'L'
    private static let innerTag: UInt8 = 0x49  // 'I'
    private static let emptyTag: UInt8 = 0x45  // 'E'

    /// Domain separation prefix
    private static let domainPrefix = "diffkey:v1|"

    /// Base tags for coupling
    private static let scratchBaseTag = "scratch"
    private static let anyBaseTag = "anybase"

    /// Empty marker for missing values
    private static let missingValueMarker = "-"

    /// Prefix markers for structured fields
    private static let xattrsPrefix = "xh:"
    private static let contentHashPrefix = "ch:"
    private static let opaquePrefix = "opq:"

    /// Node type strings
    private static let regularNodeType = "reg"
    private static let directoryNodeType = "dir"
    private static let symlinkNodeType = "sym"
    private static let deviceNodeType = "dev"
    private static let fifoNodeType = "fifo"
    private static let socketNodeType = "sock"

    /// Modification kind strings
    private static let metadataKind = "meta"
    private static let contentKind = "content"
    private static let typeKind = "type"
    private static let symlinkKind = "symlink"

    /// Empty tree marker
    private static let emptyTreeMarker = "empty"

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
        guard string.hasPrefix(Self.protocolPrefix) else {
            throw DiffKeyError.invalidFormat("unsupported format, expected \(Self.protocolPrefix)<hex>")
        }
        // Basic sanity check on hex length (64 for sha256)
        let hex = String(string.dropFirst(Self.protocolPrefix.count))
        guard hex.count == Self.sha256HexLength, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw DiffKeyError.invalidFormat("invalid sha256 hex")
        }
        self.value = string
    }

    public init(bytes: Data) {
        self.value = "\(Self.protocolPrefix)\(Self.hex(bytes))"
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

    /// Compute a canonical DiffKey from precomputed filesystem diffs.
    ///
    /// On-wire per-record format (lossless, byte-oriented):
    /// - Header: 0x01 (version) followed by record tag:
    ///     * 0x41 ('A') for Added
    ///     * 0x4D ('M') for Modified
    ///     * 0x44 ('D') for Deleted
    /// - Fields: For each record-dependent field, append as:
    ///     [len32 big-endian][UTF-8 bytes], no separators or escaping.
    ///   Numeric fields (permissions, uid, gid) are encoded as decimal strings; absent values are "-".
    ///   Link target and content hash are "-" when absent.
    ///   xattrs field is a single string "xh:<hex>" where <hex> is the deterministic xattrs hash
    ///   computed by length-prefixing key/value pairs (see xattrsHashHex(_:)).
    ///
    /// Sorting + fold-hash:
    /// - Sort the complete per-record byte sequences using unsigned byte lexicographic order.
    /// - Leaf hash: SHA256(0x4C 'L' || recordBytes)
    /// - Inner hash: SHA256(0x49 'I' || leftHash || rightHash); duplicate last leaf when odd
    /// - Empty set: SHA256(0x45 'E' || "empty")
    /// - Domain separate the final root by hashing with the prefix "diffkey:v1|<baseTag>|".
    ///
    /// Policy and limitations:
    /// - Paths are serialized as raw bytes from BinaryPath, preserving non-UTF-8 filenames exactly.
    ///   This ensures deterministic DiffKeys regardless of path encoding.
    /// - Sockets and device nodes are excluded from DiffKey records to match typical tar emission behavior.
    /// - Xattrs: values are raw bytes; keys are treated as UTF-8 strings and sorted by their UTF-8
    ///   byte order, and the tar emitter must mirror this.
    ///
    /// - Parameters:
    ///   - changes: The precomputed diff entries between base and target
    ///   - baseDigest: Optional digest of the base snapshot; baked into the root
    ///                 as a domain separator to couple reuse semantics to lineage.
    ///   - baseMount: Optional prepared mountpoint of the base; needed for deleted entry metadata
    ///   - targetMount: Prepared mountpoint of the target snapshot; needed for content hashing
    ///   - hasher: Content hasher for regular file content.
    ///   - coupleToBase: When false, baseTag becomes "anybase" and keys are parent-agnostic; when true (default) it uses baseDigest or "scratch".
    public static func computeFromDiffs(
        _ changes: [Diff],
        baseDigest: ContainerBuildIR.Digest? = nil,
        baseMount: URL? = nil,
        targetMount: URL,
        hasher: any ContentHasher = SHA256ContentHasher(),
        coupleToBase: Bool = true
    ) async throws -> DiffKey {
        // Local helper to append a field with 4-byte big-endian length prefix
        func appendField(_ string: String, to data: inout Data) {
            let bytes = Data(string.utf8)
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
            data.append(bytes)
        }

        // Helper to append a BinaryPath field with 4-byte big-endian length prefix
        func appendPathField(_ path: BinaryPath, to data: inout Data) {
            let bytes = path.rawBytes
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
            data.append(bytes)
        }

        // Build canonical per-record bytes using lossless, length-prefixed binary encoding.
        var records: [Data] = []
        records.reserveCapacity(changes.count)

        for change in changes {
            switch change {
            case .added(let a):
                // Exclude socket and device nodes from DiffKey.
                guard a.node != .socket, a.node != .device else { continue }
                var rec = Data()
                rec.append(Self.recordVersion)
                rec.append(Self.addedTag)
                let node = Self.nodeString(a.node)
                let permsField = a.permissions.map { String($0.rawValue) } ?? Self.missingValueMarker
                let uid = a.uid.map(String.init) ?? Self.missingValueMarker
                let gid = a.gid.map(String.init) ?? Self.missingValueMarker
                let lnk = a.linkTarget?.requireString ?? Self.missingValueMarker
                let xh = Self.xattrsHashHex(a.xattrs)  // hex over sorted xattrs
                let ch = try await Self.contentHashHexIfNeeded(
                    node: a.node,
                    kind: .contentChanged,  // additions imply content surfaced
                    at: targetMount.appendingPathComponent(a.path.requireString),
                    hasher: hasher
                )
                appendPathField(a.path, to: &rec)
                appendField(node, to: &rec)
                appendField(permsField, to: &rec)
                appendField(uid, to: &rec)
                appendField(gid, to: &rec)
                appendField(lnk, to: &rec)
                appendField("\(Self.xattrsPrefix)\(xh)", to: &rec)
                appendField("\(Self.contentHashPrefix)\(ch ?? Self.missingValueMarker)", to: &rec)
                records.append(rec)

            case .modified(let m):
                // Exclude socket and device nodes from DiffKey.
                guard m.node != .socket, m.node != .device else { continue }
                var rec = Data()
                rec.append(Self.recordVersion)
                rec.append(Self.modifiedTag)
                let node = Self.nodeString(m.node)
                let kind = Self.kindString(m.kind)
                let permsField = m.permissions.map { String($0.rawValue) } ?? Self.missingValueMarker
                let uid = m.uid.map(String.init) ?? Self.missingValueMarker
                let gid = m.gid.map(String.init) ?? Self.missingValueMarker
                let lnk = m.linkTarget?.requireString ?? Self.missingValueMarker
                let xh = Self.xattrsHashHex(m.xattrs)  // hex over sorted xattrs
                let ch = try await Self.contentHashHexIfNeeded(
                    node: m.node,
                    kind: m.kind,
                    at: targetMount.appendingPathComponent(m.path.requireString),
                    hasher: hasher
                )
                appendPathField(m.path, to: &rec)
                appendField(kind, to: &rec)
                appendField(node, to: &rec)
                appendField(permsField, to: &rec)
                appendField(uid, to: &rec)
                appendField(gid, to: &rec)
                appendField(lnk, to: &rec)
                appendField("\(Self.xattrsPrefix)\(xh)", to: &rec)
                appendField("\(Self.contentHashPrefix)\(ch ?? Self.missingValueMarker)", to: &rec)
                records.append(rec)

            case .deleted(let path):
                var rec = Data()
                rec.append(Self.recordVersion)
                rec.append(Self.deletedTag)
                appendPathField(path, to: &rec)

                // Determine node type and opaqueness from base
                let baseURL: URL? = {
                    guard let baseMount = baseMount else { return nil }
                    // Try to create URL from path if it's valid UTF-8
                    if let pathString = path.stringValue {
                        return baseMount.appendingPathComponent(pathString)
                    }
                    // For non-UTF8 paths, we can't determine node info from base
                    return nil
                }()
                let (nodeType, opaque) = Self.deletedNodeInfo(at: baseURL)

                // Skip sockets and device nodes for parity with policy
                if nodeType == Self.socketNodeType { continue }
                if nodeType == Self.deviceNodeType { continue }

                appendField(nodeType, to: &rec)
                appendField(opaque ? "\(Self.opaquePrefix)1" : "\(Self.opaquePrefix)0", to: &rec)

                records.append(rec)
            }
        }

        // *** Spec-compliant canonical ordering: sort by complete record bytes ***
        records.sort { $0.lexicographicallyPrecedes($1) }

        // Compute leaf hashes directly from record bytes
        var leaves: [Data] = []
        leaves.reserveCapacity(records.count)
        for rec in records {
            var h = SHA256()
            h.update(data: Data([Self.leafTag]))
            h.update(data: rec)
            leaves.append(Data(h.finalize()))
        }

        let root = Self.merkleRoot(leaves)

        // Domain separation and base coupling
        var final = SHA256()
        let baseTag: String = coupleToBase ? (baseDigest?.stringValue ?? Self.scratchBaseTag) : Self.anyBaseTag
        let prefix = "\(Self.domainPrefix)\(baseTag)|"
        if let prefixData = prefix.data(using: .utf8) {
            final.update(data: prefixData)
        }
        final.update(data: root)
        let digest = Data(final.finalize())
        return DiffKey(bytes: digest)
    }

    // MARK: - Internals

    private static func nodeString(_ node: Diff.Modified.Node) -> String {
        switch node {
        case .regular: return regularNodeType
        case .directory: return directoryNodeType
        case .symlink: return symlinkNodeType
        case .device: return deviceNodeType
        case .fifo: return fifoNodeType
        case .socket: return socketNodeType
        }
    }

    private static func kindString(_ kind: Diff.Modified.Kind) -> String {
        switch kind {
        case .metadataOnly: return metadataKind
        case .contentChanged: return contentKind
        case .typeChanged: return typeKind
        case .symlinkTargetChanged: return symlinkKind
        }
    }

    /// Deterministic xattrs hashing:
    /// - Sort entries by key using binary lex ordering of key UTF-8 bytes
    /// - For each entry, append: len32(key) + key bytes + len32(value) + value bytes
    /// - Hash the concatenated bytes with SHA-256 and return lowercase hex
    /// - Empty or missing xattrs hash to SHA-256 of empty byte stream
    private static func xattrsHashHex(_ xattrs: [String: Data]?) -> String {
        var blob = Data()

        if let xattrs, !xattrs.isEmpty {
            // Sort keys by binary lex order of UTF-8 bytes
            let sortedKeys = xattrs.keys.sorted {
                Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
            }

            for k in sortedKeys {
                let keyBytes = Data(k.utf8)
                let valBytes = xattrs[k] ?? Data()

                // len32(key) + key
                var klen = UInt32(keyBytes.count).bigEndian
                withUnsafeBytes(of: &klen) { blob.append(contentsOf: $0) }
                blob.append(keyBytes)

                // len32(value) + value
                var vlen = UInt32(valBytes.count).bigEndian
                withUnsafeBytes(of: &vlen) { blob.append(contentsOf: $0) }
                blob.append(valBytes)
            }
        }

        var h = SHA256()
        h.update(data: blob)
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
        guard kind == .contentChanged else { return nil }

        // Hash may throw if file disappeared; treat as no content hash if not present
        if !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }
        let d = try hasher.hash(fileURL: url)
        return hex(d)  // works for Data or [UInt8] via overloads
    }

    private static func merkleRoot(_ leaves: [Data]) -> Data {
        switch leaves.count {
        case 0:
            // Empty diff still produces a deterministic key
            var h = SHA256()
            h.update(data: Data([emptyTag]))
            h.update(data: Data(emptyTreeMarker.utf8))
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
                    h.update(data: Data([innerTag]))
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

    private static func deletedNodeInfo(at url: URL?) -> (String, Bool) {
        guard let url = url else { return (missingValueMarker, false) }
        var st = stat()
        let ok: Bool = url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return false }
            return lstat(cPath, &st) == 0
        }
        if !ok {
            return (missingValueMarker, false)
        }
        // Map st_mode to our node string
        let mode = st.st_mode
        let typeBits = mode & S_IFMT
        let nodeType: String
        switch typeBits {
        case S_IFREG: nodeType = regularNodeType
        case S_IFDIR: nodeType = directoryNodeType
        case S_IFLNK: nodeType = symlinkNodeType
        case S_IFCHR, S_IFBLK: nodeType = deviceNodeType
        case S_IFIFO: nodeType = fifoNodeType
        case S_IFSOCK: nodeType = socketNodeType
        default: nodeType = missingValueMarker
        }
        var opaque = false
        if nodeType == directoryNodeType {
            opaque = baseDirectoryHadChildren(at: url)
        }
        return (nodeType, opaque)
    }

    private static func baseDirectoryHadChildren(at url: URL) -> Bool {
        // Returns true if directory exists and has at least one entry (excluding "." and "..")
        if let children = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            return !children.isEmpty
        }
        return false
    }

    // MARK: - Hex helpers (overloads for Data and [UInt8])

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
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
