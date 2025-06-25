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

import Collections
import ContainerClient
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import GRPC

actor BuildFSSync: BuildPipelineHandler {
    let contextDir: URL

    init(_ contextDir: URL) throws {
        guard FileManager.default.fileExists(atPath: contextDir.cleanPath) else {
            throw Error.contextNotFound(contextDir.cleanPath)
        }
        guard try contextDir.isDir() else {
            throw Error.contextIsNotDirectory(contextDir.cleanPath)
        }

        self.contextDir = contextDir
    }

    nonisolated func accept(_ packet: ServerStream) throws -> Bool {
        guard let buildTransfer = packet.getBuildTransfer() else {
            return false
        }
        guard buildTransfer.stage() == "fssync" else {
            return false
        }
        return true
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: ServerStream) async throws {
        guard let buildTransfer = packet.getBuildTransfer() else {
            throw Error.buildTransferMissing
        }
        guard let method = buildTransfer.method() else {
            throw Error.methodMissing
        }
        switch try FSSyncMethod(method) {
        case .read:
            try await self.read(sender, buildTransfer, packet.buildID)
        case .info:
            try await self.info(sender, buildTransfer, packet.buildID)
        case .walk:
            try await self.walk(sender, buildTransfer, packet.buildID)
        }
    }

    func read(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: BuildTransfer, _ buildID: String) async throws {
        let offset: UInt64 = packet.offset() ?? 0
        let size: Int = packet.len() ?? 0
        var path: URL
        if packet.source.hasPrefix("/") {
            path = URL(fileURLWithPath: packet.source).standardizedFileURL
        } else {
            path =
                contextDir
                .appendingPathComponent(packet.source)
                .standardizedFileURL
        }
        if !FileManager.default.fileExists(atPath: path.cleanPath) {
            path = URL(filePath: self.contextDir.cleanPath)
            path.append(components: packet.source.cleanPathComponent)
        }
        let data = try {
            if try path.isDir() {
                return Data()
            }
            let file = try LocalContent(path: path.standardizedFileURL)
            return try file.data(offset: offset, length: size) ?? Data()
        }()

        let transfer = try path.buildTransfer(id: packet.id, contextDir: self.contextDir, complete: true, data: data)
        var response = ClientStream()
        response.buildID = buildID
        response.buildTransfer = transfer
        response.packetType = .buildTransfer(transfer)
        sender.yield(response)
    }

    func info(_ sender: AsyncStream<ClientStream>.Continuation, _ packet: BuildTransfer, _ buildID: String) async throws {
        let path: URL
        if packet.source.hasPrefix("/") {
            path = URL(fileURLWithPath: packet.source).standardizedFileURL
        } else {
            path =
                contextDir
                .appendingPathComponent(packet.source)
                .standardizedFileURL
        }
        let transfer = try path.buildTransfer(id: packet.id, contextDir: self.contextDir, complete: true)
        var response = ClientStream()
        response.buildID = buildID
        response.buildTransfer = transfer
        response.packetType = .buildTransfer(transfer)
        sender.yield(response)
    }

    private struct DirEntry: Hashable {
        let url: URL
        let isDirectory: Bool
        let relativePath: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(relativePath)
        }

        static func == (lhs: DirEntry, rhs: DirEntry) -> Bool {
            lhs.relativePath == rhs.relativePath
        }
    }

    func walk(
        _ sender: AsyncStream<ClientStream>.Continuation,
        _ packet: BuildTransfer,
        _ buildID: String
    ) async throws {
        let wantsTar = packet.mode() == "tar"

        var entries: [String: Set<DirEntry>] = [:]
        let followPaths: [String] = packet.followPaths() ?? []

        let followPathsWalked = try walk(root: self.contextDir, includePatterns: followPaths)
        for url in followPathsWalked {
            guard self.contextDir.absoluteURL.cleanPath != url.absoluteURL.cleanPath else {
                continue
            }
            guard self.contextDir.parentOf(url) else {
                continue
            }

            let relPath = try url.relativeChildPath(to: contextDir)
            let parentPath = try url.deletingLastPathComponent().relativeChildPath(to: contextDir)
            let entry = DirEntry(url: url, isDirectory: url.hasDirectoryPath, relativePath: relPath)
            entries[parentPath, default: []].insert(entry)

            if url.isSymlink {
                let target: URL = url.resolvingSymlinksInPath()
                if self.contextDir.parentOf(target) {
                    let relPath = try target.relativeChildPath(to: self.contextDir)
                    let entry = DirEntry(url: target, isDirectory: target.hasDirectoryPath, relativePath: relPath)
                    let parentPath: String = try target.deletingLastPathComponent().relativeChildPath(to: self.contextDir)
                    entries[parentPath, default: []].insert(entry)
                }
            }
        }

        var fileOrder = [String]()
        try processDirectory("", inputEntries: entries, processedPaths: &fileOrder)

        if !wantsTar {
            let fileInfos = try fileOrder.map { rel -> FileInfo in
                try FileInfo(path: contextDir.appendingPathComponent(rel), contextDir: contextDir)
            }

            let data = try JSONEncoder().encode(fileInfos)
            let transfer = BuildTransfer(
                id: packet.id,
                source: packet.source,
                complete: true,
                isDir: false,
                metadata: [
                    "os": "linux",
                    "stage": "fssync",
                    "mode": "json",
                ],
                data: data
            )
            var resp = ClientStream()
            resp.buildID = buildID
            resp.buildTransfer = transfer
            resp.packetType = .buildTransfer(transfer)
            sender.yield(resp)
            return
        }

        let tarURL = URL.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tar")

        defer { try? FileManager.default.removeItem(at: tarURL) }

        let writerCfg = ArchiveWriterConfiguration(
            format: .paxRestricted,
            filter: .none)

        try Archiver.compress(
            source: contextDir,
            destination: tarURL,
            writerConfiguration: writerCfg
        ) { url in
            guard let rel = try? url.relativeChildPath(to: contextDir) else {
                return nil
            }

            guard let parent = try? url.deletingLastPathComponent().relativeChildPath(to: self.contextDir) else {
                return nil
            }

            guard let items = entries[parent] else {
                return nil
            }

            let include = items.contains { item in
                item.relativePath == rel
            }

            guard include else {
                return nil
            }

            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: rel))
        }

        for try await chunk in try tarURL.bufferedCopyReader() {
            let part = BuildTransfer(
                id: packet.id,
                source: tarURL.path,
                complete: false,
                isDir: false,
                metadata: [
                    "os": "linux",
                    "stage": "fssync",
                    "mode": "tar",
                ],
                data: chunk
            )
            var resp = ClientStream()
            resp.buildID = buildID
            resp.buildTransfer = part
            resp.packetType = .buildTransfer(part)
            sender.yield(resp)
        }

        let done = BuildTransfer(
            id: packet.id,
            source: tarURL.path,
            complete: true,
            isDir: false,
            metadata: [
                "os": "linux",
                "stage": "fssync",
                "mode": "tar",
            ],
            data: Data()
        )

        var finalResp = ClientStream()
        finalResp.buildID = buildID
        finalResp.buildTransfer = done
        finalResp.packetType = .buildTransfer(done)
        sender.yield(finalResp)
    }

    func walk(root: URL, includePatterns: [String]) throws -> [URL] {
        let globber = Globber(root)

        for p in includePatterns {
            try globber.match(p)
        }
        return Array(globber.results)
    }

    private func processDirectory(
        _ currentDir: String,
        inputEntries: [String: Set<DirEntry>],
        processedPaths: inout [String]
    ) throws {
        guard let entries = inputEntries[currentDir] else {
            return
        }

        // Sort purely by lexicographical order of relativePath
        let sortedEntries = entries.sorted { $0.relativePath < $1.relativePath }

        for entry in sortedEntries {
            processedPaths.append(entry.relativePath)

            if entry.isDirectory {
                try processDirectory(
                    entry.relativePath,
                    inputEntries: inputEntries,
                    processedPaths: &processedPaths
                )
            }
        }
    }

    struct FileInfo: Codable {
        let name: String
        let modTime: String
        let mode: UInt32
        let size: UInt64
        let isDir: Bool
        let uid: UInt32
        let gid: UInt32
        let target: String

        init(path: URL, contextDir: URL) throws {
            if path.isSymlink {
                let target: URL = path.resolvingSymlinksInPath()
                if contextDir.parentOf(target) {
                    self.target = target.relativePathFrom(from: path)
                } else {
                    self.target = target.cleanPath
                }
            } else {
                self.target = ""
            }

            self.name = try path.relativeChildPath(to: contextDir)
            self.modTime = try path.modTime()
            self.mode = try path.mode()
            self.size = try path.size()
            self.isDir = path.hasDirectoryPath
            self.uid = 0
            self.gid = 0
        }
    }

    enum FSSyncMethod: String {
        case read = "Read"
        case info = "Info"
        case walk = "Walk"

        init(_ method: String) throws {
            switch method {
            case "Read":
                self = .read
            case "Info":
                self = .info
            case "Walk":
                self = .walk
            default:
                throw Error.unknownMethod(method)
            }
        }
    }
}

extension BuildFSSync {
    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case buildTransferMissing
        case methodMissing
        case unknownMethod(String)
        case contextNotFound(String)
        case contextIsNotDirectory(String)
        case couldNotDetermineFileSize(String)
        case couldNotDetermineModTime(String)
        case couldNotDetermineFileMode(String)
        case invalidOffsetSizeForFile(String, UInt64, Int)
        case couldNotDetermineUID(String)
        case couldNotDetermineGID(String)
        case pathIsNotChild(String, String)

        var description: String {
            switch self {
            case .buildTransferMissing:
                return "buildTransfer field missing in packet"
            case .methodMissing:
                return "method is missing in request"
            case .unknownMethod(let m):
                return "unknown content-store method \(m)"
            case .contextNotFound(let path):
                return "context dir \(path) not found"
            case .contextIsNotDirectory(let path):
                return "context \(path) not a directory"
            case .couldNotDetermineFileSize(let path):
                return "could not determine size of file \(path)"
            case .couldNotDetermineModTime(let path):
                return "could not determine last modified time of \(path)"
            case .couldNotDetermineFileMode(let path):
                return "could not determine posix permissions (FileMode) of \(path)"
            case .invalidOffsetSizeForFile(let digest, let offset, let size):
                return "invalid request for file: \(digest) with offset: \(offset) size: \(size)"
            case .couldNotDetermineUID(let path):
                return "could not determine UID of file at path: \(path)"
            case .couldNotDetermineGID(let path):
                return "could not determine GID of file at path: \(path)"
            case .pathIsNotChild(let path, let parent):
                return "\(path) is not a child of \(parent)"
            }
        }
    }
}

extension BuildTransfer {
    fileprivate init(id: String, source: String, complete: Bool, isDir: Bool, metadata: [String: String], data: Data? = nil) {
        self.init()
        self.id = id
        self.source = source
        self.direction = .outof
        self.complete = complete
        self.metadata = metadata
        self.isDirectory = isDir
        if let data {
            self.data = data
        }
    }
}

extension URL {
    fileprivate func size() throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: self.cleanPath)
        if let size = attrs[FileAttributeKey.size] as? UInt64 {
            return size
        }
        throw BuildFSSync.Error.couldNotDetermineFileSize(self.cleanPath)
    }

    fileprivate func modTime() throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: self.cleanPath)
        if let date = attrs[FileAttributeKey.modificationDate] as? Date {
            return date.rfc3339()
        }
        throw BuildFSSync.Error.couldNotDetermineModTime(self.cleanPath)
    }

    fileprivate func isDir() throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: self.cleanPath)
        guard let t = attrs[.type] as? FileAttributeType, t == .typeDirectory else {
            return false
        }
        return true
    }

    fileprivate func mode() throws -> UInt32 {
        let attrs = try FileManager.default.attributesOfItem(atPath: self.cleanPath)
        if let mode = attrs[FileAttributeKey.posixPermissions] as? NSNumber {
            return mode.uint32Value
        }
        throw BuildFSSync.Error.couldNotDetermineFileMode(self.cleanPath)
    }

    fileprivate func uid() throws -> UInt32 {
        let attrs = try FileManager.default.attributesOfItem(atPath: self.cleanPath)
        if let uid = attrs[.ownerAccountID] as? UInt32 {
            return uid
        }
        throw BuildFSSync.Error.couldNotDetermineUID(self.cleanPath)
    }

    fileprivate func gid() throws -> UInt32 {
        let attrs = try FileManager.default.attributesOfItem(atPath: self.cleanPath)
        if let gid = attrs[.groupOwnerAccountID] as? UInt32 {
            return gid
        }
        throw BuildFSSync.Error.couldNotDetermineGID(self.cleanPath)
    }

    fileprivate func buildTransfer(
        id: String,
        contextDir: URL? = nil,
        complete: Bool = false,
        data: Data = Data()
    ) throws -> BuildTransfer {
        let p = try {
            if let contextDir { return try self.relativeChildPath(to: contextDir) }
            return self.cleanPath
        }()
        return BuildTransfer(
            id: id,
            source: String(p),
            complete: complete,
            isDir: try self.isDir(),
            metadata: [
                "os": "linux",
                "stage": "fssync",
                "mode": String(try self.mode()),
                "size": String(try self.size()),
                "modified_at": try self.modTime(),
                "uid": String(try self.uid()),
                "gid": String(try self.gid()),
            ],
            data: data
        )
    }
}

extension Date {
    fileprivate func rfc3339() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)  // Adjust if necessary

        return dateFormatter.string(from: self)
    }
}

extension String {
    var cleanPathComponent: String {
        let trimmed = self.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let clean = trimmed.removingPercentEncoding {
            return clean
        }
        return trimmed
    }
}
