//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerAPIClient
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Foundation
import GRPCCore

/// Handles the `content-store` stage of the build protocol.
///
/// Proxies image-layer blob requests from BuildKit to the host's local
/// containerd content store. BuildKit issues these requests when it needs
/// base-image layers that are not already present in the builder VM.
struct BuildRemoteContentProxy: BuildPipelineHandler {
    let local: ContentStore
    let writes: WriteSessions
    /// Where a committed blob is put. The store gains the whole set when the
    /// build's images are recorded, so until then a blob lives here and the
    /// store does not hold it. Reads answer from here as well, because a
    /// writer asks the store what it holds before writing and reads back what
    /// it wrote, and neither can see this directory.
    let ingestDir: URL?

    public init(_ contentStore: ContentStore, ingestDir: URL? = nil) throws {
        self.local = contentStore
        self.writes = WriteSessions()
        self.ingestDir = ingestDir
    }

    /// The path a committed blob takes in the gathering directory, which names
    /// it by digest alone under the store's algorithm directory, the way the
    /// store names it.
    private func gathered(_ digest: String) -> URL? {
        self.ingestDir?.appendingPathComponent(digest.trimmingDigestPrefix)
    }

    /// A blob the build holds, whether the store has taken it or it is still
    /// gathered here. Asking the store first and the gathering directory
    /// second is how importing an image resolves a blob it may itself have
    /// only just written.
    private func held(_ digest: String) async throws -> Content? {
        if let content = try await local.get(digest: digest) {
            return content
        }
        guard let path = gathered(digest) else {
            return nil
        }
        return try? LocalContent(path: path)
    }

    /// The same, for the question a writer asks before writing.
    ///
    /// A writer skips whatever the store says it holds, so a blob answered for
    /// here is one this build will not write and still needs: it belongs to
    /// the image about to be recorded, and until that record exists nothing
    /// claims it and a sweep is free to take it. The build gathers a copy, so
    /// what it names is what it hands over. Importing an image copies the
    /// blobs the store already holds into its own ingest for the same reason.
    private func heldForWriter(_ digest: String) async throws -> Content? {
        guard let path = gathered(digest) else {
            return try await local.get(digest: digest)
        }
        if let content = try? LocalContent(path: path) {
            return content
        }
        guard let found = try await local.get(digest: digest) else {
            return nil
        }
        try? FileManager.default.copyItem(at: found.path, to: path)
        return found
    }

    /// The blobs BuildKit is streaming into the store, one temporary file per
    /// ref, appended chunk by chunk until the commit seals it. The digest is
    /// computed as the chunks arrive, the way containerd's own ingest writer
    /// keeps it, so the commit finalizes and compares rather than re-reading
    /// the file.
    actor WriteSessions {
        struct Open {
            let url: URL
            let handle: FileHandle
            var written: UInt64
            var hasher: SHA256
        }

        private var open: [String: Open] = [:]
        /// Where this build's blobs are written, made when the first one
        /// arrives and taken away when the build ends.
        let dir: URL

        init() {
            self.dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("build-blob-writes-\(UUID().uuidString)")
        }

        func append(ref: String, offset: UInt64, data: Data) throws -> UInt64 {
            var session: Open
            if let existing = open[ref] {
                session = existing
            } else {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                session = Open(url: url, handle: try FileHandle(forWritingTo: url), written: 0, hasher: SHA256())
            }
            // An offset the write names must be the one the session is at,
            // and a zero offset asks for the blob again from its beginning:
            // the session drops the bytes it holds and rebuilds the digest
            // over what arrives next, which is how a writer restarts a blob
            // it has already begun.
            // https://github.com/containerd/containerd/blob/main/plugins/services/content/contentserver/contentserver.go
            // https://github.com/containerd/containerd/blob/main/plugins/content/local/writer.go
            if offset > 0 {
                guard offset == session.written else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "write for \(ref) at offset \(offset), \(session.written) bytes held"
                    )
                }
            } else if session.written > 0 {
                session.written = 0
                session.hasher = SHA256()
                try session.handle.seek(toOffset: 0)
                try session.handle.truncate(atOffset: 0)
            }
            try session.handle.write(contentsOf: data)
            session.written += UInt64(data.count)
            session.hasher.update(data: data)
            open[ref] = session
            return session.written
        }

        /// Lets go of every blob still being written and takes the directory
        /// holding them with it.
        ///
        /// A blob is committed one at a time, and the commit takes its file out
        /// of here; what remains when the build ends is what the build began
        /// and never sealed, which nothing will ask for again. The protocol
        /// carries no word for abandoning a single blob, so the end of the
        /// stream is the only word there is.
        func discardAll() {
            for session in open.values {
                try? session.handle.close()
                try? FileManager.default.removeItem(at: session.url)
            }
            open.removeAll()
            try? FileManager.default.removeItem(at: dir)
        }

        func close(ref: String) throws -> (url: URL, written: UInt64, digest: String)? {
            guard let session = open.removeValue(forKey: ref) else {
                return nil
            }
            // The bytes must be on disk before the commit renames the file
            // into the store, or a crash commits a hole where content should
            // be, which is why the reference syncs before it stats.
            try session.handle.synchronize()
            try session.handle.close()
            let digest = "sha256:" + session.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (session.url, session.written, digest)
        }
    }

    func accept(_ packet: ServerStream) throws -> Bool {
        guard let imageTransfer = packet.getImageTransfer() else {
            return false
        }
        guard imageTransfer.stage() == "content-store" else {
            return false
        }
        return true
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws {
        guard let imageTransfer = packet.getImageTransfer() else {
            throw Error.imageTransferMissing
        }

        guard let method = imageTransfer.method() else {
            throw Error.methodMissing
        }

        switch try ContentStoreMethod(method) {
        case .info:
            try await self.info(sender, imageTransfer, packet.buildID)
        case .readerAt:
            try await self.readerAt(sender, imageTransfer, packet.buildID)
        case .write:
            try await self.write(sender, imageTransfer, packet.buildID)
        default:
            throw Error.unknownMethod(method)
        }
    }

    func info(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer, _ buildID: String) async throws {
        let content = try await heldForWriter(packet.tag)
        let size = try content?.size()
        var transfer = try ImageTransfer(
            id: packet.id,
            digest: packet.tag,
            method: ContentStoreMethod.info.rawValue,
            size: size
        )
        if content == nil {
            // A store answers an info request for a digest it does not hold
            // with not found, and that answer is what tells a writer the blob
            // has still to be written: an export asks before it writes and
            // skips whatever the store says it already holds, so an answer
            // describing a blob that is not there loses the export's blobs.
            // https://github.com/containerd/containerd/blob/main/plugins/content/local/store.go
            transfer.metadata["error"] = "content \(packet.tag) not found"
        }
        var response = ClientStream()
        response.buildID = buildID
        response.imageTransfer = transfer
        response.packetType = .imageTransfer(transfer)
        sender.yield(response)
    }

    func readerAt(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer, _ buildID: String) async throws {
        let digest = packet.descriptor.digest
        let offset: UInt64 = packet.offset() ?? 0
        let size: Int = packet.len() ?? 0
        guard let content = try await held(digest) else {
            throw Error.contentMissing
        }
        if offset == 0 && size == 0 {  // Metadata request
            var transfer = try ImageTransfer(
                id: packet.id,
                digest: packet.tag,
                method: ContentStoreMethod.readerAt.rawValue,
                size: content.size(),
                data: Data()
            )
            transfer.complete = true
            var response = ClientStream()
            response.buildID = buildID
            response.imageTransfer = transfer
            response.packetType = .imageTransfer(transfer)
            sender.yield(response)
            return
        }
        guard let data = try content.data(offset: offset, length: size) else {
            throw Error.invalidOffsetSizeForContent(packet.descriptor.digest, offset, size)
        }

        let transfer = try ImageTransfer(
            id: packet.id,
            digest: packet.tag,
            method: ContentStoreMethod.readerAt.rawValue,
            size: UInt64(data.count),
            data: data
        )
        var response = ClientStream()
        response.buildID = buildID
        response.imageTransfer = transfer
        response.packetType = .imageTransfer(transfer)
        sender.yield(response)
    }

    /// A blob BuildKit exports arrives as write packets carrying sequential
    /// chunks and a commit packet carrying the digest and size the whole must
    /// verify to. The chunks gather in a temporary file, and the commit moves
    /// it into the store through an ingest session, which is what dedups a
    /// blob the store already holds. The commit's checks are the receiving
    /// store's obligations under containerd's writer contract, kept in the
    /// reference's order and spellings:
    /// https://github.com/containerd/containerd/blob/main/plugins/content/local/writer.go
    /// The reply mirrors the shim's writer contract: offset for a write,
    /// exists for a commit the store already satisfied, error for anything
    /// that failed.
    func write(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer, _ buildID: String) async throws {
        let action = packet.metadata["action"] ?? ""
        let ref = packet.metadata["ref"] ?? packet.id
        var reply: [String: String] = [:]

        do {
            switch action {
            case "write":
                let offset = UInt64(packet.metadata["offset"] ?? "0") ?? 0
                let written = try await writes.append(ref: ref, offset: offset, data: packet.data)
                reply["offset"] = String(written)
            case "commit":
                guard let expected = packet.metadata["expected"] else {
                    throw ContainerizationError(.invalidArgument, message: "commit for \(ref) names no digest")
                }
                let total = UInt64(packet.metadata["total"] ?? "0") ?? 0
                let closed = try await writes.close(ref: ref)
                do {
                    if try await local.get(digest: expected) != nil {
                        reply["exists"] = "true"
                        if let closed {
                            try? FileManager.default.removeItem(at: closed.url)
                        }
                        break
                    }
                    guard let closed else {
                        throw ContainerizationError(.invalidArgument, message: "commit for \(ref) with no bytes written")
                    }
                    guard total == 0 || closed.written == total else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "unexpected commit size \(closed.written), expected \(total) for \(ref)"
                        )
                    }
                    guard closed.digest == expected else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "unexpected commit digest \(closed.digest), expected \(expected) for \(ref)"
                        )
                    }
                    // A blob is named for its digest alone under the store's
                    // algorithm directory, which is the name a later read
                    // resolves; a name carrying the algorithm again lands a
                    // file nothing looks for.
                    //
                    // The blob is gathered rather than handed to the store,
                    // and the store takes the whole set when it records the
                    // images naming them, so it never holds a blob that no
                    // image claims. A build given nowhere to gather hands it
                    // over as it arrives.
                    if let destination = gathered(expected) {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: closed.url)
                        } else {
                            try FileManager.default.moveItem(at: closed.url, to: destination)
                        }
                    } else {
                        let session = try await local.newIngestSession()
                        try FileManager.default.moveItem(
                            at: closed.url,
                            to: session.ingestDir.appendingPathComponent(expected.trimmingDigestPrefix)
                        )
                        _ = try await local.completeIngestSession(session.id)
                    }
                    reply["offset"] = String(closed.written)
                } catch {
                    // A failed commit leaves nothing behind, the way the
                    // reference removes its ingest path on the way out.
                    if let closed {
                        try? FileManager.default.removeItem(at: closed.url)
                    }
                    throw error
                }
            default:
                throw Error.unknownMethod("\(ContentStoreMethod.write.rawValue) action \(action)")
            }
        } catch {
            reply["error"] = "\(error)"
        }

        var transfer = try ImageTransfer(
            id: packet.id,
            digest: packet.tag,
            method: ContentStoreMethod.write.rawValue
        )
        for (key, value) in reply {
            transfer.metadata[key] = value
        }
        var response = ClientStream()
        response.buildID = buildID
        response.imageTransfer = transfer
        response.packetType = .imageTransfer(transfer)
        sender.yield(response)
    }

    func delete(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer) async throws {
        throw NSError(domain: "RemoteContentProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "unimplemented method \(ContentStoreMethod.delete)"])
    }

    func update(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer) async throws {
        throw NSError(domain: "RemoteContentProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "unimplemented method \(ContentStoreMethod.update)"])
    }

    func walk(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ImageTransfer) async throws {
        throw NSError(domain: "RemoteContentProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "unimplemented method \(ContentStoreMethod.walk)"])
    }

    enum ContentStoreMethod: String {
        case info = "/containerd.services.content.v1.Content/Info"
        case readerAt = "/containerd.services.content.v1.Content/ReaderAt"
        case write = "/containerd.services.content.v1.Content/Write"
        case delete = "/containerd.services.content.v1.Content/Delete"
        case update = "/containerd.services.content.v1.Content/Update"
        case walk = "/containerd.services.content.v1.Content/Walk"

        init(_ method: String) throws {
            guard let value = ContentStoreMethod(rawValue: method) else {
                throw Error.unknownMethod(method)
            }
            self = value
        }
    }
}

extension ImageTransfer {
    fileprivate init(id: String, digest: String, method: String, size: UInt64? = nil, data: Data = Data()) throws {
        self.init()
        self.id = id
        self.tag = digest
        self.metadata = [
            "os": "linux",
            "stage": "content-store",
            "method": method,
        ]
        if let size {
            self.metadata["size"] = String(size)
        }
        self.complete = true
        self.direction = .into
        self.data = data
    }
}

extension BuildRemoteContentProxy {
    enum Error: Swift.Error, CustomStringConvertible {
        case imageTransferMissing
        case methodMissing
        case contentMissing
        case unknownMethod(String)
        case invalidOffsetSizeForContent(String, UInt64, Int)

        var description: String {
            switch self {
            case .imageTransferMissing:
                return "imageTransfer is missing"
            case .methodMissing:
                return "method is missing in request"
            case .contentMissing:
                return "content cannot be found"
            case .unknownMethod(let m):
                return "unknown content-store method \(m)"
            case .invalidOffsetSizeForContent(let digest, let offset, let size):
                return "invalid request for content: \(digest) with offset: \(offset) size: \(size)"
            }
        }
    }

}
