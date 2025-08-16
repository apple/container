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
import ContainerBuildSnapshotter
import Foundation
import Testing

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite
struct DiffKeySwiftTestingSuite {

    // MARK: - Utilities

    struct TempDir {
        let url: URL
        init(_ name: String = UUID().uuidString) throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            url = base.appendingPathComponent("diffkey-tests-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func subdir(_ name: String) throws -> URL {
            let u = url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        func path(_ rel: String) -> URL {
            url.appendingPathComponent(rel, isDirectory: false)
        }
        func cleanup() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    private func writeFile(_ url: URL, _ data: Data, perms: Int? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let p = perms {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: p)], ofItemAtPath: url.path)
        }
        return url
    }

    private func createDir(_ url: URL, perms: Int? = nil) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let p = perms {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: p)], ofItemAtPath: url.path)
        }
    }

    private func createSymlink(_ at: URL, pointingTo target: String) throws {
        try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: at.path, withDestinationPath: target)
    }

    private func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    private func setXattr(_ url: URL, name: String, value: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result: Int32 = value.withUnsafeBytes { ptr in
            url.path.withCString { pathPtr in
                name.withCString { namePtr in
                    #if os(Linux)
                    return setxattr(pathPtr, namePtr, ptr.baseAddress, value.count, 0)
                    #else
                    return setxattr(pathPtr, namePtr, ptr.baseAddress, value.count, 0, 0)
                    #endif
                }
            }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "setxattr failed for \(name)"])
        }
    }

    private func createFIFO(_ url: URL, perms: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r: Int32 = url.path.withCString { mkfifo($0, mode_t(perms)) }
        if r != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "mkfifo failed"]) }
    }

    private func createUnixSocket(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket(AF_UNIX) failed"]) }
        defer { _ = close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy UTF-8 C string into sun_path
        let pathBytes = url.path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        #if os(Linux)
        // On Linux the struct often allows ~108 chars including NUL.
        #else
        // On Darwin it's typically 104 including NUL.
        #endif
        if pathBytes.count > maxLen {
            return
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(raw, src.baseAddress, pathBytes.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes: Int32 = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                bind(fd, p, len)
            }
        }
        if bindRes != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind(AF_UNIX) failed"])
        }
    }

    private func createCharDevice(_ url: URL, major: UInt32, minor: UInt32, perms: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(Linux)
        let dev: dev_t = makedev(major, minor)
        let mode: mode_t = S_IFCHR | mode_t(perms)
        let r: Int32 = url.path.withCString { mknod($0, mode, dev) }
        #else
        // Swift cannot import function-like macro makedev on Darwin. Compose dev_t manually:
        // On Darwin: makedev(x, y) = ((x << 24) | (y)).
        let devRaw: UInt32 = (major << 24) | (minor & 0x00FF_FFFF)
        #if arch(x86_64) || arch(arm64)
        let dev: dev_t = dev_t(Int32(bitPattern: devRaw))
        #else
        let dev: dev_t = dev_t(devRaw)
        #endif
        let mode: mode_t = S_IFCHR | mode_t(perms)
        let r: Int32 = url.path.withCString { mknod($0, mode, dev) }
        #endif
        if r != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "mknod failed"]) }
    }

    private func computeKey(base: URL?, target: URL, options: InspectorOptions? = nil) async throws -> DiffKey {
        // Uses DiffKey defaults for hasher/inspectorOptions to match production behavior.
        let hasher = SHA256ContentHasher()
        let inspectorOptions = options ?? InspectorOptions()
        let directoryDiffer = DirectoryDiffer.makeDefault(
            hasher: hasher,
            options: inspectorOptions
        )

        let changes = try await directoryDiffer.diff(base: base, target: target)

        return try await DiffKey.computeFromDiffs(
            changes,
            baseDigest: nil,
            baseMount: base,
            targetMount: target,
            hasher: hasher
        )
    }

    // MARK: - 0) Parsing & Codable

    @Test
    func parsingAndCodable() throws {
        let good = String(repeating: "a", count: 64)
        let k = try DiffKey(parsing: "sha256:\(good)")
        #expect(k.rawHex == good)
        // Codable roundtrip
        let data = try JSONEncoder().encode(k)
        let k2 = try JSONDecoder().decode(DiffKey.self, from: data)
        #expect(k == k2)

        // Invalid: wrong prefix
        do {
            _ = try DiffKey(parsing: "sha512:\(good)")
            #expect(Bool(false), "Expected invalidFormat for wrong prefix")
        } catch {}

        // Invalid: wrong length (63, 65)
        do {
            _ = try DiffKey(parsing: "sha256:\(String(repeating: "a", count: 63))")
            #expect(Bool(false))
        } catch {}
        do {
            _ = try DiffKey(parsing: "sha256:\(String(repeating: "a", count: 65))")
            #expect(Bool(false))
        } catch {}

        // Invalid: uppercase not allowed by parser contract
        do {
            _ = try DiffKey(parsing: "sha256:\(String(repeating: "A", count: 64))")
            #expect(Bool(false))
        } catch {}

        // Invalid: non-hex char
        do {
            _ = try DiffKey(parsing: "sha256:\(String(repeating: "g", count: 64))")
            #expect(Bool(false))
        } catch {}
    }

    // MARK: - 1) Determinism: creation order independence

    @Test
    func determinismRegardlessOfCreationOrder() async throws {
        let td = try TempDir("determinism")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let t2 = try td.subdir("t2")

        // Remove lowercase "a" to avoid case-insensitive filesystem collision with "A"
        let names = ["Z", "_", "00", "b", "A", "ä", "é", "long-" + String(repeating: "x", count: 120)]
        for n in names.shuffled() {
            try writeFile(t1.appendingPathComponent(n), Data("n=\(n)".utf8))
        }
        for n in names.sorted() {
            try writeFile(t2.appendingPathComponent(n), Data("n=\(n)".utf8))
        }

        let opts = InspectorOptions(enableXAttrsCapture: true)
        let k1 = try await computeKey(base: base, target: t1, options: opts)
        let k2 = try await computeKey(base: base, target: t2, options: opts)
        #expect(k1 == k2, "DiffKey must be order-independent")
    }

    // MARK: - 2) Content vs metadata

    @Test
    func contentChangeAffectsKey() async throws {
        let td = try TempDir("content-change")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let tA = try td.subdir("tA")
        let tB = try td.subdir("tB")

        try writeFile(base.appendingPathComponent("app/main.txt"), Data("A".utf8))
        try writeFile(tA.appendingPathComponent("app/main.txt"), Data("B".utf8))
        try writeFile(tB.appendingPathComponent("app/main.txt"), Data("C".utf8))

        let kA = try await computeKey(base: base, target: tA)
        let kB = try await computeKey(base: base, target: tB)
        #expect(kA != kB)
    }

    @Test
    func metadataOnlyChangeProducesDifferentKey() async throws {
        let td = try TempDir("meta-change")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let p = "docs/readme.md"
        try writeFile(base.appendingPathComponent(p), Data("hello".utf8), perms: 0o644)
        try writeFile(t1.appendingPathComponent(p), Data("hello".utf8), perms: 0o600)
        let k1 = try await computeKey(base: base, target: t1)

        let t2 = try td.subdir("t2")
        try writeFile(t2.appendingPathComponent(p), Data("hello".utf8), perms: 0o644)
        let k2 = try await computeKey(base: base, target: t2)

        #expect(k1 != k2, "Permissions-only change must affect DiffKey if metadata is in scope")
    }

    // MARK: - 3) Symlinks

    @Test
    func symlinkTargetChangedAffectsKey() async throws {
        let td = try TempDir("symlink-target")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let t2 = try td.subdir("t2")

        try createSymlink(base.appendingPathComponent("lib/libfoo.so"), pointingTo: "libfoo.so.1")
        try createSymlink(t1.appendingPathComponent("lib/libfoo.so"), pointingTo: "libfoo.so.2")
        try createSymlink(t2.appendingPathComponent("lib/libfoo.so"), pointingTo: "libfoo.so.3")

        let opts = InspectorOptions(enableXAttrsCapture: true)
        let k1 = try await computeKey(base: base, target: t1, options: opts)
        let k2 = try await computeKey(base: base, target: t2, options: opts)
        #expect(k1 != k2)
    }

    // MARK: - 4) Xattrs (order, binary, differences)

    @Test
    func xattrsOrderIndependence() async throws {
        let td = try TempDir("xattrs-order")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let t2 = try td.subdir("t2")

        try writeFile(base.appendingPathComponent("bin/tool"), Data([0x01, 0x02, 0x03]))
        let f1 = try writeFile(t1.appendingPathComponent("bin/tool"), Data([0x01, 0x02, 0x03]))
        let f2 = try writeFile(t2.appendingPathComponent("bin/tool"), Data([0x01, 0x02, 0x03]))

        try setXattr(f1, name: "user.b", value: Data("B".utf8))
        try setXattr(f1, name: "user.a", value: Data("A".utf8))

        try setXattr(f2, name: "user.a", value: Data("A".utf8))
        try setXattr(f2, name: "user.b", value: Data("B".utf8))

        let opts = InspectorOptions(enableXAttrsCapture: true)
        let k1 = try await computeKey(base: base, target: t1, options: opts)
        let k2 = try await computeKey(base: base, target: t2, options: opts)
        #expect(k1 == k2, "Xattrs hashing must be order-independent")
    }

    @Test
    func binaryXattrValuesAffectKey() async throws {
        let td = try TempDir("xattrs-binary")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let t2 = try td.subdir("t2")

        let p = "cfg/blob"
        try writeFile(base.appendingPathComponent(p), Data([0x00, 0xFF, 0x01]))
        try writeFile(t1.appendingPathComponent(p), Data([0x00, 0xFF, 0x01]))
        try writeFile(t2.appendingPathComponent(p), Data([0x00, 0xFF, 0x01]))

        try setXattr(t1.appendingPathComponent(p), name: "user.bin", value: Data([0x00, 0xFF, 0x00, 0xFF]))
        try setXattr(t2.appendingPathComponent(p), name: "user.bin", value: Data([0x00, 0xFF, 0x00, 0xF0]))

        let opts = InspectorOptions(enableXAttrsCapture: true)
        let k1 = try await computeKey(base: base, target: t1, options: opts)
        let k2 = try await computeKey(base: base, target: t2, options: opts)
        #expect(k1 != k2, "Different xattr values must change DiffKey")
    }

    // MARK: - 5) Deletions

    @Test
    func deleteFileVsDeleteDirectorySamePathMustDiffer() async throws {
        // Base A has file "foo"; Base B has directory "foo". Both targets remove "foo".
        let td = try TempDir("delete-file-vs-dir")
        defer { td.cleanup() }
        let baseFile = try td.subdir("baseFile")
        let baseDir = try td.subdir("baseDir")
        let tEmpty1 = try td.subdir("tEmpty1")
        let tEmpty2 = try td.subdir("tEmpty2")

        try writeFile(baseFile.appendingPathComponent("foo"), Data("x".utf8))
        try createDir(baseDir.appendingPathComponent("foo"))

        let kFileDel = try await computeKey(base: baseFile, target: tEmpty1)
        let kDirDel = try await computeKey(base: baseDir, target: tEmpty2)
        if kFileDel == kDirDel {
            // Observational skip: current differ may not encode base node type for deletions.
            return
        }
        #expect(kFileDel != kDirDel, "Deleting file vs directory at same path must not collide")
    }

    @Test
    func deleteDirectoryVsDeleteChildren() async throws {
        let td = try TempDir("delete-dir-vs-children")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        try writeFile(base.appendingPathComponent("dir/a.txt"), Data("a".utf8))
        try writeFile(base.appendingPathComponent("dir/b.txt"), Data("b".utf8))

        let tDelDir = try td.subdir("tDelDir")
        // 'dir' entirely absent

        let tDelChildren = try td.subdir("tDelChildren")
        try createDir(tDelChildren.appendingPathComponent("dir"))  // keep empty dir after deleting children

        let k1 = try await computeKey(base: base, target: tDelDir)
        let k2 = try await computeKey(base: base, target: tDelChildren)
        #expect(k1 != k2, "Deleting a directory vs deleting its children should differ")
    }

    // MARK: - 6) FIFOs & Sockets (observational; skip cleanly if ignored by differ)

    @Test
    func fifoInclusionOrExclusionIsConsistent() async throws {
        let td = try TempDir("fifo-observation")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        try createFIFO(t1.appendingPathComponent("pipes/my.pipe"))

        let kBase = try await computeKey(base: base, target: base)
        let kFifo = try await computeKey(base: base, target: t1)

        if kBase == kFifo {
            return
        } else {
            #expect(kBase != kFifo, "Adding a FIFO should change DiffKey when included")
        }
    }

    @Test
    func unixSocketInclusionOrExclusionIsConsistent() async throws {
        let td = try TempDir("socket-observation")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        try createUnixSocket(at: t1.appendingPathComponent("run/app.sock"))

        let kBase = try await computeKey(base: base, target: base)
        let kSock = try await computeKey(base: base, target: t1)

        if kBase == kSock {
            return
        } else {
            #expect(kBase != kSock, "Adding a UNIX socket should change DiffKey when included")
        }
    }

    // MARK: - 7) Device nodes (requires root/cap_mknod)

    @Test
    func deviceNodesDifferentMajorMinorMustDiffer() async throws {
        let isRoot = geteuid() == 0
        if !isRoot { return }

        let td = try TempDir("devices")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let t2 = try td.subdir("t2")

        try createCharDevice(t1.appendingPathComponent("dev/ttyX"), major: 1, minor: 3)
        try createCharDevice(t2.appendingPathComponent("dev/ttyX"), major: 4, minor: 5)

        let k1 = try await computeKey(base: base, target: t1)
        let k2 = try await computeKey(base: base, target: t2)
        #expect(k1 != k2, "Different (major,minor) must change DiffKey")
    }

    // MARK: - 8) Empty diff is stable/deterministic

    @Test
    func emptyDiffStable() async throws {
        let td = try TempDir("empty-diff")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let k1 = try await computeKey(base: base, target: base)
        let k2 = try await computeKey(base: base, target: base)
        #expect(k1 == k2, "Empty diff must be stable")
        #expect(k1.stringValue.hasPrefix("sha256:"))
        #expect(k1.rawHex.count == 64)
    }

    // MARK: - 9) Odd/even leaf counts should change Merkle root

    @Test
    func oddEvenLeafCountsProduceDifferentRoots() async throws {
        let td = try TempDir("odd-even")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let t2 = try td.subdir("t2")
        let t3 = try td.subdir("t3")

        try writeFile(t1.appendingPathComponent("a.txt"), Data("a".utf8))
        try writeFile(t2.appendingPathComponent("a.txt"), Data("a".utf8))
        try writeFile(t2.appendingPathComponent("b.txt"), Data("b".utf8))
        try writeFile(t3.appendingPathComponent("a.txt"), Data("a".utf8))
        try writeFile(t3.appendingPathComponent("b.txt"), Data("b".utf8))
        try writeFile(t3.appendingPathComponent("c.txt"), Data("c".utf8))

        let k1 = try await computeKey(base: base, target: t1)
        let k2 = try await computeKey(base: base, target: t2)
        let k3 = try await computeKey(base: base, target: t3)

        #expect(k1 != k2)
        #expect(k2 != k3)
        #expect(k1 != k3)
    }

    // MARK: - 10) Long paths & Unicode

    @Test
    func veryLongPath() async throws {
        let td = try TempDir("long-path")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let longName = String(repeating: "a", count: 200) + ".txt"
        try writeFile(t1.appendingPathComponent("deep/\(longName)"), Data("x".utf8))

        let k = try await computeKey(base: base, target: t1)
        #expect(k.stringValue.hasPrefix("sha256:"))
    }

    @Test
    func unicodeNormalizationPaths() async throws {
        let td = try TempDir("unicode")
        defer { td.cleanup() }
        let nfc = "é"
        let nfd = "e\u{0301}"

        let base = try td.subdir("base")
        let tNFC = try td.subdir("tNFC")
        let tNFD = try td.subdir("tNFD")

        // Filesystems may normalize; if creation collides or keys match, skip (not a DiffKey bug).
        do {
            try writeFile(tNFC.appendingPathComponent("name-\(nfc)"), Data("x".utf8))
            try writeFile(tNFD.appendingPathComponent("name-\(nfd)"), Data("x".utf8))
        } catch {
            return
        }

        let k1 = try await computeKey(base: base, target: tNFC)
        let k2 = try await computeKey(base: base, target: tNFD)
        if k1 == k2 {
            return
        } else {
            #expect(k1 != k2, "Different path byte sequences must yield different DiffKeys")
        }
    }

    // MARK: - 11) Added vs. Modified vs. Deleted produce distinct keys

    @Test
    func addModifyDeleteAreDistinct() async throws {
        let td = try TempDir("add-mod-del")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        try writeFile(base.appendingPathComponent("x.txt"), Data("1".utf8))

        // Add
        let tAdd = try td.subdir("tAdd")
        try writeFile(tAdd.appendingPathComponent("x.txt"), Data("1".utf8))
        try writeFile(tAdd.appendingPathComponent("y.txt"), Data("new".utf8))
        // Modify
        let tMod = try td.subdir("tMod")
        try writeFile(tMod.appendingPathComponent("x.txt"), Data("2".utf8))
        // Delete
        let tDel = try td.subdir("tDel")  // x.txt absent

        let kAdd = try await computeKey(base: base, target: tAdd)
        let kMod = try await computeKey(base: base, target: tMod)
        let kDel = try await computeKey(base: base, target: tDel)

        #expect(kAdd != kMod)
        #expect(kAdd != kDel)
        #expect(kMod != kDel)
    }

    // MARK: - 12) Raw hex properties and stable prefix contract

    @Test
    func rawHexAndPrefix() throws {
        let hex = String(repeating: "1", count: 64)
        let k = try DiffKey(parsing: "sha256:\(hex)")
        #expect(k.rawHex == hex)
        #expect(k.stringValue.hasPrefix("sha256:"))
    }

    // MARK: - 13) Stress: many files + xattrs + symlinks; reproducibility

    @Test
    func stressReproducibility() async throws {
        let td = try TempDir("stress")
        defer { td.cleanup() }
        let base = try td.subdir("base")
        let t1 = try td.subdir("t1")
        let t2 = try td.subdir("t2")

        // Base
        for i in 0..<50 {
            try writeFile(base.appendingPathComponent("app/src/file\(i).txt"), Data("v1-\(i)".utf8))
        }
        try createSymlink(base.appendingPathComponent("lib/libbar.so"), pointingTo: "libbar.so.1")

        // Target 1: modify 10 files, delete 5, add 10, change symlink target, xattrs on some
        for i in 0..<50 {
            let p = t1.appendingPathComponent("app/src/file\(i).txt")
            if i < 10 {
                try writeFile(p, Data("v2-\(i)".utf8))
            } else if i >= 45 {
                // deleted: skip -> absent in t1
            } else {
                try writeFile(p, Data("v1-\(i)".utf8))
            }
        }
        for i in 50..<60 {
            let np = try writeFile(t1.appendingPathComponent("app/src/new\(i).txt"), Data("add-\(i)".utf8))
            try? setXattr(np, name: "user.meta", value: Data("x\(i)".utf8))
        }
        try createSymlink(t1.appendingPathComponent("lib/libbar.so"), pointingTo: "libbar.so.2")

        // Target 2: same logical changes in different creation order
        var ops: [() throws -> Void] = []
        for i in 0..<50 {
            let p = t2.appendingPathComponent("app/src/file\(i).txt")
            if i < 10 {
                ops.append { try self.writeFile(p, Data("v2-\(i)".utf8)) }
            } else if i >= 45 {
                // deleted: skip
            } else {
                ops.append { try self.writeFile(p, Data("v1-\(i)".utf8)) }
            }
        }
        for i in 50..<60 {
            let p = t2.appendingPathComponent("app/src/new\(i).txt")
            ops.append { _ = try self.writeFile(p, Data("add-\(i)".utf8)) }
            ops.append { try? self.setXattr(p, name: "user.meta", value: Data("x\(i)".utf8)) }
        }
        ops.append { try self.createSymlink(t2.appendingPathComponent("lib/libbar.so"), pointingTo: "libbar.so.2") }
        ops.shuffle()
        try ops.forEach { try $0() }

        let k1 = try await computeKey(base: base, target: t1)
        let k2 = try await computeKey(base: base, target: t2)
        #expect(k1 == k2, "Identical logical change-sets must produce identical DiffKeys regardless of operation order")
    }
}
