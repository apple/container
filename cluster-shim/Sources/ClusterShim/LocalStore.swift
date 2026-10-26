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

import ContainerizationOCI
import Crypto
import Foundation
import GRPCCore
import Synchronization

/// A blob in a content store.
struct BlobInfo: Sendable, Equatable {
    var digest: String
    var size: Int64
    var createdAt: Date
    var updatedAt: Date
}

/// An in-progress write to the local store.
struct IngestStatus: Sendable, Equatable {
    var ref: String
    var offset: Int64
    var total: Int64
    var startedAt: Date
    var updatedAt: Date
}

/// The node's local content store, with containerd's local store layout and
/// rules. Blobs live under `blobs/sha256` and are read and deleted through
/// ContainerizationOCI's `LocalContentStore`. In-progress writes live under
/// `ingest/<sha256 of ref>`, holding `ref`, `data`, `startedat`, `updatedat`
/// and, when known, `total`.
final class LocalStore: Sendable {
    let root: URL
    private let blobs: LocalContentStore
    private let lockedRefs = Mutex<Set<String>>([])

    init(root: URL) throws {
        self.root = root
        self.blobs = try LocalContentStore(path: root)
    }

    var blobsDirectory: URL {
        root.appendingPathComponent("blobs/sha256")
    }

    var ingestDirectory: URL {
        root.appendingPathComponent("ingest")
    }

    func info(digest: String) async throws -> BlobInfo {
        let content = try await self.content(digest: digest)
        return try Self.blobInfo(path: content.path)
    }

    /// Returns up to `length` bytes of a blob starting at `offset`.
    func read(digest: String, offset: Int64, length: Int) async throws -> Data {
        let content = try await self.content(digest: digest)
        guard let data = try content.data(offset: UInt64(offset), length: length) else {
            return Data()
        }
        return data
    }

    /// Lists every blob in the store.
    func walk() throws -> [BlobInfo] {
        let names = try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)
        var infos: [BlobInfo] = []
        for name in names {
            guard ParsedDigest.isValid(name) else {
                continue
            }
            infos.append(try Self.blobInfo(path: blobsDirectory.appendingPathComponent(name)))
        }
        return infos
    }

    /// Deletes a blob. Deleting a missing blob succeeds, as in containerd's local store.
    func delete(digest: String) async throws {
        _ = try Self.parse(digest: digest)
        try await blobs.delete(digests: [digest])
    }

    /// Opens a writer for `ref`, resuming an earlier write to the same ref.
    func writer(ref: String, total: Int64, expected: String) async throws -> IngestWriter {
        guard !ref.isEmpty else {
            throw RPCError(code: .invalidArgument, message: "ref must not be empty")
        }
        try lock(ref: ref)
        do {
            if !expected.isEmpty, try await blobs.get(digest: try Self.parse(digest: expected).description) != nil {
                throw RPCError(code: .alreadyExists, message: "content \(expected): already exists")
            }
            return try IngestWriter(store: self, ref: ref, directory: ingestDirectory(ref: ref), total: total)
        } catch {
            unlock(ref: ref)
            throw error
        }
    }

    func status(ref: String) throws -> IngestStatus {
        try Self.ingestStatus(directory: ingestDirectory(ref: ref))
    }

    /// Lists in-progress writes, skipping ones that finish while listing.
    func listStatuses() throws -> [IngestStatus] {
        let names = try FileManager.default.contentsOfDirectory(atPath: ingestDirectory.path)
        var statuses: [IngestStatus] = []
        for name in names {
            do {
                statuses.append(try Self.ingestStatus(directory: ingestDirectory.appendingPathComponent(name)))
            } catch let error as RPCError where error.code == .notFound {
                continue
            }
        }
        return statuses
    }

    func abort(ref: String) throws {
        let directory = ingestDirectory(ref: ref)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw RPCError(code: .notFound, message: "ingest ref \(ref): not found")
        }
        try FileManager.default.removeItem(at: directory)
    }

    func ingestDirectory(ref: String) -> URL {
        ingestDirectory.appendingPathComponent(SHA256.hash(data: Data(ref.utf8)).encoded)
    }

    func lock(ref: String) throws {
        let locked = lockedRefs.withLock { refs in
            refs.insert(ref).inserted
        }
        guard locked else {
            throw RPCError(code: .unavailable, message: "ref \(ref) locked")
        }
    }

    func unlock(ref: String) {
        _ = lockedRefs.withLock { refs in
            refs.remove(ref)
        }
    }

    private func content(digest: String) async throws -> any Content {
        let parsed = try Self.parse(digest: digest)
        guard let content = try await blobs.get(digest: parsed.description) else {
            throw RPCError(code: .notFound, message: "content \(digest): not found")
        }
        return content
    }

    /// Parses a `sha256:<hex>` digest, mapping a malformed one to invalidArgument.
    static func parse(digest: String) throws -> ParsedDigest {
        do {
            return try ParsedDigest(parsing: digest)
        } catch {
            throw RPCError(code: .invalidArgument, message: "invalid digest \(digest)")
        }
    }

    private static func blobInfo(path: URL) throws -> BlobInfo {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = try modificationTime(path: path.path)
        return BlobInfo(digest: "sha256:\(path.lastPathComponent)", size: size, createdAt: modified, updatedAt: modified)
    }

    /// Reads the status of an ingest directory. Updated is the later of the
    /// `updatedat` file, written when a writer closes, and the data's
    /// modification time.
    static func ingestStatus(directory: URL) throws -> IngestStatus {
        let dataPath = directory.appendingPathComponent("data").path
        let refPath = directory.appendingPathComponent("ref").path
        guard let dataAttributes = try? FileManager.default.attributesOfItem(atPath: dataPath),
            let ref = try? String(contentsOfFile: refPath, encoding: .utf8)
        else {
            throw RPCError(code: .notFound, message: "ingest \(directory.lastPathComponent): not found")
        }
        let updatedAt = try readTimestamp(from: directory.appendingPathComponent("updatedat"))
        return IngestStatus(
            ref: ref,
            offset: (dataAttributes[.size] as? NSNumber)?.int64Value ?? 0,
            total: readTotal(directory: directory),
            startedAt: try readTimestamp(from: directory.appendingPathComponent("startedat")),
            updatedAt: max(updatedAt, try modificationTime(path: dataPath))
        )
    }

    /// Reads the `total` file of an ingest directory. A missing file is 0, an unknown total.
    static func readTotal(directory: URL) -> Int64 {
        let path = directory.appendingPathComponent("total").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let total = Int64(text) else {
            return 0
        }
        return total
    }
}

/// Writes one ingest for the length of a containerd `Write` call. It holds the
/// ref's lock until `commit` or `close`.
final class IngestWriter {
    let ref: String
    let startedAt: Date
    private(set) var updatedAt: Date
    private(set) var total: Int64
    private(set) var offset: Int64
    private let store: LocalStore
    private let directory: URL
    private var hasher: SHA256
    private var file: FileHandle?

    /// Opens the ingest in `directory`, resuming its data when its ref and
    /// total match, and starting it over otherwise.
    init(store: LocalStore, ref: String, directory: URL, total: Int64) throws {
        let fileManager = FileManager.default
        let dataURL = directory.appendingPathComponent("data")
        self.store = store
        self.ref = ref
        self.directory = directory
        self.hasher = SHA256()

        if let status = try? LocalStore.ingestStatus(directory: directory),
            status.ref == ref,
            total == 0 || status.total == 0 || total == status.total
        {
            self.startedAt = status.startedAt
            self.updatedAt = status.updatedAt
            self.total = status.total
            self.offset = status.offset
            try Self.hash(fileAt: dataURL, into: &self.hasher)
        } else {
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            try Data(ref.utf8).write(to: directory.appendingPathComponent("ref"))
            try writeTimestamp(now, to: directory.appendingPathComponent("startedat"))
            try writeTimestamp(now, to: directory.appendingPathComponent("updatedat"))
            if total > 0 {
                try Data(String(total).utf8).write(to: directory.appendingPathComponent("total"))
            }
            guard fileManager.createFile(atPath: dataURL.path, contents: nil) else {
                throw RPCError(code: .internalError, message: "create \(dataURL.path)")
            }
            self.startedAt = now
            self.updatedAt = now
            self.total = total
            self.offset = 0
        }

        let file = try FileHandle(forWritingTo: dataURL)
        try file.seek(toOffset: UInt64(self.offset))
        self.file = file
    }

    /// The digest of the data written so far.
    var digest: String {
        ParsedDigest(hasher.finalize()).description
    }

    func write(_ data: Data) throws {
        guard let file else {
            throw RPCError(code: .failedPrecondition, message: "cannot write on closed writer")
        }
        try file.write(contentsOf: data)
        hasher.update(data: data)
        offset += Int64(data.count)
        updatedAt = Date()
    }

    /// Discards the data written so far. containerd only truncates to 0.
    func truncate() throws {
        guard let file else {
            throw RPCError(code: .failedPrecondition, message: "cannot truncate closed writer")
        }
        try file.truncate(atOffset: 0)
        hasher = SHA256()
        offset = 0
    }

    /// Moves the data into the blob store after checking its size and digest,
    /// then removes the ingest. Releases the ref's lock either way.
    func commit(size: Int64, expected: String) throws {
        guard let file else {
            throw RPCError(code: .failedPrecondition, message: "cannot commit on closed writer")
        }
        self.file = nil
        defer { store.unlock(ref: ref) }

        try file.synchronize()
        try file.close()

        let fileManager = FileManager.default
        let dataURL = directory.appendingPathComponent("data")
        let attributes = try fileManager.attributesOfItem(atPath: dataURL.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > 0 && size != actualSize {
            throw RPCError(code: .failedPrecondition, message: "unexpected commit size \(actualSize), expected \(size)")
        }
        let actualDigest = digest
        if !expected.isEmpty && expected != actualDigest {
            throw RPCError(code: .failedPrecondition, message: "unexpected commit digest \(actualDigest), expected \(expected)")
        }

        let target = try LocalStore.parse(digest: actualDigest).path(in: store.blobsDirectory)
        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.removeItem(at: directory)
            throw RPCError(code: .alreadyExists, message: "content \(actualDigest): already exists")
        }
        try fileManager.moveItem(at: dataURL, to: target)
        try fileManager.setAttributes([.modificationDate: Date(), .posixPermissions: 0o444], ofItemAtPath: target.path)
        try? fileManager.removeItem(at: directory)
    }

    /// Releases the ref's lock and keeps the data so a later writer can resume.
    func close() {
        guard let file else {
            return
        }
        try? file.synchronize()
        try? file.close()
        try? writeTimestamp(updatedAt, to: directory.appendingPathComponent("updatedat"))
        self.file = nil
        store.unlock(ref: ref)
    }

    private static func hash(fileAt url: URL, into hasher: inout SHA256) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }
}
