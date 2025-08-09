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

import Darwin
import Foundation

/// Result of metadata comparison between two nodes
public enum FileMetadataDiffResult: Equatable {
    case noChange
    case metadataOnly
    case typeChanged
    case symlinkTargetChanged
}

/// Compares NormalizedFileAttributes for metadata differences.
public struct FileMetadataDiffer: Sendable {

    public init() {}

    public func diff(
        old: NormalizedFileAttributes,
        new: NormalizedFileAttributes,
        options: InspectorOptions
    ) -> FileMetadataDiffResult {
        // If type changed, treat as stronger than metadata-only
        if old.type != new.type {
            return .typeChanged
        }

        // Symlink target is considered content for symlinks
        if old.type == .symlink {
            if old.symlinkTarget != new.symlinkTarget {
                return .symlinkTargetChanged
            }
        }

        // Metadata fields that contribute to metadata-only classification
        let modeChanged = (old.mode ?? 0) != (new.mode ?? 0)
        let uidChanged = (old.uid ?? 0) != (new.uid ?? 0)
        let gidChanged = (old.gid ?? 0) != (new.gid ?? 0)

        // Timestamps already normalized in inspector
        let mtimeChanged = (old.mtimeNS ?? 0) != (new.mtimeNS ?? 0)
        let ctimeChanged = (old.ctimeNS ?? 0) != (new.ctimeNS ?? 0)

        // Size is not metadata-only for regular files; for other types it's metadata
        var sizeChanged = false
        if old.type == .regular || new.type == .regular {
            sizeChanged = (old.size ?? -1) != (new.size ?? -1)
        }

        // Xattrs digest presence and inequality indicates metadata-only change
        let xattrsDigestChanged: Bool = {
            let od = digestOfXAttrs(old)
            let nd = digestOfXAttrs(new)
            return od != nd
        }()

        // Aggregate metadata-only fields
        let anyMetadataChange =
            modeChanged || uidChanged || gidChanged || mtimeChanged || ctimeChanged || xattrsDigestChanged
            || (!sizeChanged && old.type != .regular && new.type != .regular && (old.size ?? -1) != (new.size ?? -1))

        if anyMetadataChange {
            return .metadataOnly
        }
        return .noChange
    }

    private func digestOfXAttrs(_ a: NormalizedFileAttributes) -> Data? {
        guard !a.xattrs.isEmpty else { return nil }
        // Simple canonical concat as a stand-in for the full encode when only comparing
        var out = Data()
        for e in a.xattrs {
            if let k = e.key.data(using: .utf8) {
                out.append(k)
            }
            out.append(e.value)
        }
        return out
    }

    /// Convenience: diff by reading attributes using the default inspector.
    public func diff(
        oldURL: URL,
        newURL: URL,
        options: InspectorOptions = InspectorOptions()
    ) async throws -> FileMetadataDiffResult {
        let inspector = DefaultFileAttributeInspector()
        let oldAttrs = try await inspector.inspect(url: oldURL, options: options)
        let newAttrs = try await inspector.inspect(url: newURL, options: options)
        return diff(old: oldAttrs, new: newAttrs, options: options)
    }
}

/// Canonicalized extended attribute entry
public struct XAttrEntry: Equatable, Codable {
    public let key: String  // canonical key: namespace:name in lowercase
    public let value: Data
}

/// Options controlling attribute inspection and normalization
public struct InspectorOptions: Equatable, Sendable {
    public var enableXAttrsCapture: Bool
    public var xattrIgnoreList: Set<String>  // canonical keys to ignore
    public var xattrMaxBytes: Int  // cap on total xattr bytes per file
    public var followSymlinks: Bool  // if true, stat follows symlinks, else lstat
    public var timestampGranularityNS: Int64  // clamp timestamps to this granularity

    public init(
        enableXAttrsCapture: Bool = false,
        xattrIgnoreList: Set<String> = [],
        xattrMaxBytes: Int = 262_144,
        followSymlinks: Bool = false,
        timestampGranularityNS: Int64 = 1_000_000  // 1 ms
    ) {
        self.enableXAttrsCapture = enableXAttrsCapture
        self.xattrIgnoreList = xattrIgnoreList
        self.xattrMaxBytes = xattrMaxBytes
        self.followSymlinks = followSymlinks
        self.timestampGranularityNS = timestampGranularityNS
    }
}

/// Errors from attribute inspection
public enum AttributeError: Error, LocalizedError {
    case ioError(String, code: Int32)
    case notFound(String)
    case permissionDenied(String)
    case xattrTooLarge(path: String, limit: Int)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .ioError(let what, let code): return "\(what) failed with errno \(code)"
        case .notFound(let path): return "Path not found: \(path)"
        case .permissionDenied(let path): return "Permission denied: \(path)"
        case .xattrTooLarge(let path, let limit): return "xattrs exceed cap \(limit) for \(path)"
        case .unsupported(let what): return "Unsupported feature: \(what)"
        }
    }
}

/// File system node type
public enum FileNodeType: String, Codable {
    case regular
    case directory
    case symlink
    case characterDevice
    case blockDevice
    case fifo
    case socket
}

/// Normalized and canonicalized file attributes
public struct NormalizedFileAttributes: Equatable, Codable {
    // Identification
    public var path: String?  // optional, relative if provided by caller
    public var type: FileNodeType

    // Ownership and permissions
    public var mode: UInt16?
    public var uid: UInt32?
    public var gid: UInt32?

    // Size and times
    public var size: Int64?
    public var mtimeNS: Int64?  // epoch nanos, UTC, clamped
    public var ctimeNS: Int64?  // epoch nanos, UTC, clamped

    // Device/inode identity
    public var device: UInt64?
    public var inode: UInt64?

    // Platform-specific flags / security labels
    public var flags: UInt64?
    public var posixACL: Data?
    public var linuxCapabilities: Data?
    public var selinuxLabel: String?

    // Symlink
    public var symlinkTarget: String?

    // XAttrs (canonicalized)
    public var xattrs: [XAttrEntry]

    // Additional attributes surfaced for archiving without OS re-reads
    public var devMajor: UInt32?  // major(st_rdev) for block/char devices
    public var devMinor: UInt32?  // minor(st_rdev) for block/char devices
    public var nlink: UInt64?  // hard-link count

    public init(
        path: String? = nil,
        type: FileNodeType,
        mode: UInt16? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        size: Int64? = nil,
        mtimeNS: Int64? = nil,
        ctimeNS: Int64? = nil,
        device: UInt64? = nil,
        inode: UInt64? = nil,
        flags: UInt64? = nil,
        posixACL: Data? = nil,
        linuxCapabilities: Data? = nil,
        selinuxLabel: String? = nil,
        symlinkTarget: String? = nil,
        xattrs: [XAttrEntry] = [],
        devMajor: UInt32? = nil,
        devMinor: UInt32? = nil,
        nlink: UInt64? = nil
    ) {
        self.path = path
        self.type = type
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.mtimeNS = mtimeNS
        self.ctimeNS = ctimeNS
        self.device = device
        self.inode = inode
        self.flags = flags
        self.posixACL = posixACL
        self.linuxCapabilities = linuxCapabilities
        self.selinuxLabel = selinuxLabel
        self.symlinkTarget = symlinkTarget
        self.xattrs = xattrs
        self.devMajor = devMajor
        self.devMinor = devMinor
        self.nlink = nlink
    }
}

/// Inspector for structured, normalized file metadata with canonical xattrs
public protocol FileAttributeInspector: Sendable {
    func inspect(url: URL, options: InspectorOptions) async throws -> NormalizedFileAttributes
    func listXAttrs(url: URL, options: InspectorOptions) async throws -> [XAttrEntry]
}

/// macOS-only implementation using POSIX stat, lstat, and listxattr/getxattr.
public struct DefaultFileAttributeInspector: FileAttributeInspector, Sendable {

    public init() {}

    public func inspect(url: URL, options: InspectorOptions) async throws -> NormalizedFileAttributes {
        let path = url.withUnsafeFileSystemRepresentation { fsr -> String in
            if let fsr = fsr { return String(cString: fsr) }
            return url.path
        }

        var st = stat()
        let rc: Int32
        if options.followSymlinks {
            rc = path.withCString { stat($0, &st) }
        } else {
            rc = path.withCString { lstat($0, &st) }
        }

        if rc != 0 {
            switch errno {
            case ENOENT: throw AttributeError.notFound(path)
            case EACCES: throw AttributeError.permissionDenied(path)
            default: throw AttributeError.ioError("stat/lstat(\(path))", code: errno)
            }
        }

        let nodeType = Self.nodeType(from: st)
        let mode = UInt16(st.st_mode) & 0o7777
        let uid = UInt32(st.st_uid)
        let gid = UInt32(st.st_gid)
        let size: Int64? = (nodeType == .regular || nodeType == .symlink) ? Int64(st.st_size) : nil

        let mtimeNSraw = Self.epochNanos(fromMTime: st)
        let ctimeNSraw = Self.epochNanos(fromCTime: st)
        let mtimeNS = Self.clamp(nanos: mtimeNSraw, granularity: options.timestampGranularityNS)
        let ctimeNS = Self.clamp(nanos: ctimeNSraw, granularity: options.timestampGranularityNS)

        // Compute additional attributes needed downstream without re-reading
        let nlink = UInt64(st.st_nlink)
        var devMajorNum: UInt32? = nil
        var devMinorNum: UInt32? = nil
        if nodeType == .characterDevice || nodeType == .blockDevice {
            devMajorNum = UInt32((UInt32(st.st_rdev) >> 24) & 0xff)
            devMinorNum = UInt32(st.st_rdev & 0xffffff)
        }

        var attrs = NormalizedFileAttributes(
            path: nil,
            type: nodeType,
            mode: mode,
            uid: uid,
            gid: gid,
            size: size,
            mtimeNS: mtimeNS,
            ctimeNS: ctimeNS,
            device: UInt64(bitPattern: Int64(st.st_dev)),
            inode: UInt64(bitPattern: Int64(st.st_ino)),
            flags: nil,
            posixACL: nil,
            linuxCapabilities: nil,
            selinuxLabel: nil,
            symlinkTarget: nil,
            xattrs: [],
            devMajor: devMajorNum,
            devMinor: devMinorNum,
            nlink: nlink
        )

        // Symlink target (when not following symlinks)
        if nodeType == .symlink && !options.followSymlinks {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                attrs.symlinkTarget = target
            }
        }

        // Extended attributes (canonicalized)
        if options.enableXAttrsCapture {
            let list = try? await listXAttrs(url: url, options: options)
            attrs.xattrs = list ?? []
        }

        return attrs
    }

    public func listXAttrs(url: URL, options: InspectorOptions) async throws -> [XAttrEntry] {
        let path = url.withUnsafeFileSystemRepresentation { fsr -> String in
            if let fsr = fsr { return String(cString: fsr) }
            return url.path
        }

        // First call with size 0 to get required buffer size
        let sizeNeeded = path.withCString { cstr -> ssize_t in
            listxattr(cstr, nil, 0, 0)
        }

        if sizeNeeded < 0 {
            // If xattrs unsupported or permission denied, treat as empty set
            if errno == ENOTSUP || errno == EACCES || errno == EPERM {
                return []
            }
            throw AttributeError.ioError("listxattr(\(path))", code: errno)
        }

        if sizeNeeded == 0 {
            return []
        }

        var nameBuf = [CChar](repeating: 0, count: Int(sizeNeeded))
        let got = path.withCString { cstr -> ssize_t in
            listxattr(cstr, &nameBuf, nameBuf.count, 0)
        }

        if got < 0 {
            if errno == ENOTSUP || errno == EACCES || errno == EPERM {
                return []
            }
            throw AttributeError.ioError("listxattr(\(path))", code: errno)
        }

        // Parse null-separated names
        var entries: [XAttrEntry] = []
        var totalBytes = 0
        var idx = 0
        while idx < got {
            var end = idx
            while end < got && nameBuf[Int(end)] != 0 { end += 1 }
            if end == idx {
                idx += 1
                continue
            }
            let name = nameBuf[Int(idx)...].withUnsafeBytes { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }

            // Canonicalize key
            let canonicalKey = Self.canonicalizeXAttrKey(rawKey: name)

            // Ignore list
            if options.xattrIgnoreList.contains(canonicalKey) {
                idx = Int(end + 1)
                continue
            }

            // Fetch value
            let valueSize = path.withCString { cstr -> ssize_t in
                getxattr(cstr, name, nil, 0, 0, 0)
            }

            if valueSize < 0 {
                // Skip unreadable attributes silently for robustness when configured
                idx = Int(end + 1)
                continue
            }

            var val = [UInt8](repeating: 0, count: Int(valueSize))
            let gotVal = path.withCString { cstr -> ssize_t in
                getxattr(cstr, name, &val, val.count, 0, 0)
            }
            if gotVal < 0 {
                idx = Int(end + 1)
                continue
            }

            // Cap total bytes per file
            if totalBytes + Int(gotVal) > options.xattrMaxBytes {
                // Stop collecting further xattrs and signal size cap
                throw AttributeError.xattrTooLarge(path: path, limit: options.xattrMaxBytes)
            }

            entries.append(XAttrEntry(key: canonicalKey, value: Data(val[0..<Int(gotVal)])))
            totalBytes += Int(gotVal)

            idx = Int(end + 1)
        }

        // Sort by canonical key byte-wise order (string compare is sufficient for ASCII keys)
        entries.sort { $0.key < $1.key }
        return entries
    }
}

// Helpers
extension DefaultFileAttributeInspector {
    static func nodeType(from st: stat) -> FileNodeType {
        let m = st.st_mode
        if (m & S_IFMT) == S_IFDIR { return .directory }
        if (m & S_IFMT) == S_IFLNK { return .symlink }
        if (m & S_IFMT) == S_IFREG { return .regular }
        if (m & S_IFMT) == S_IFCHR { return .characterDevice }
        if (m & S_IFMT) == S_IFBLK { return .blockDevice }
        if (m & S_IFMT) == S_IFIFO { return .fifo }
        if (m & S_IFMT) == S_IFSOCK { return .socket }
        return .regular
    }

    static func epochNanos(fromMTime st: stat) -> Int64 {
        let sec = Int64(st.st_mtimespec.tv_sec)
        let nsec = Int64(st.st_mtimespec.tv_nsec)
        return sec &* 1_000_000_000 &+ nsec
    }

    static func epochNanos(fromCTime st: stat) -> Int64 {
        let sec = Int64(st.st_ctimespec.tv_sec)
        let nsec = Int64(st.st_ctimespec.tv_nsec)
        return sec &* 1_000_000_000 &+ nsec
    }

    static func clamp(nanos: Int64, granularity: Int64) -> Int64 {
        guard granularity > 0 else { return nanos }
        // Floor to the nearest multiple of granularity
        return (nanos / granularity) * granularity
    }

    /// Canonicalize xattr key to lowercase "namespace:name" when possible.
    /// - Examples:
    ///   - user.foo -> user:foo
    ///   - security.selinux -> security:selinux
    ///   - com.apple.quarantine stays com.apple.quarantine (no namespace delimiter)
    static func canonicalizeXAttrKey(rawKey: String) -> String {
        let lower = rawKey.lowercased()
        if let dot = lower.firstIndex(of: ".") {
            let ns = lower[..<dot]
            let name = lower[lower.index(after: dot)...]
            if !ns.isEmpty && !name.isEmpty {
                return "\(ns):\(name)"
            }
        }
        return lower
    }
}
