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

import ContainerizationArchive
import ContainerizationOS
import CryptoKit
import Darwin
import Foundation

public final class Archiver: Sendable {
    private struct FileStatus {
        enum EntryType {
            case directory
            case regular
            case symbolicLink
        }

        let entryType: EntryType
        let permissions: UInt16
        let size: Int64
        let owner: UInt32
        let group: UInt32
        let creationDate: Date?
        let modificationDate: Date?
        let symlinkTarget: String?
    }

    public struct ArchiveEntryInfo: Sendable, Codable {
        public let pathOnHost: URL
        public let pathInArchive: URL

        public let owner: UInt32?
        public let group: UInt32?
        public let permissions: UInt16?

        public init(
            pathOnHost: URL,
            pathInArchive: URL,
            owner: UInt32? = nil,
            group: UInt32? = nil,
            permissions: UInt16? = nil
        ) {
            self.pathOnHost = pathOnHost
            self.pathInArchive = pathInArchive
            self.owner = owner
            self.group = group
            self.permissions = permissions
        }
    }

    private struct ArchiveEntryHashInfo: Encodable {
        let pathOnHost: String
        let pathInArchive: String
        let owner: UInt32?
        let group: UInt32?
        let permissions: UInt16?
        let fileType: String
        let symlinkTarget: String?
        let size: Int64?
    }

    public static func compress(
        source: URL,
        destination: URL,
        followSymlinks: Bool = false,
        writerConfiguration: ArchiveWriterConfiguration = ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip),
        closure: (URL) -> ArchiveEntryInfo?
    ) throws -> SHA256.Digest {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)

        var hasher = SHA256()

        do {
            let directory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            guard
                let enumerator = FileManager.default.enumerator(atPath: source.path)
            else {
                throw Error.fileDoesNotExist(source)
            }

            var entryInfo = [ArchiveEntryInfo]()
            if !source.isDirectory {
                if let info = closure(source) {
                    entryInfo.append(info)
                }
            } else {
                let relPaths = enumerator.compactMap { $0 as? String }
                for relPath in relPaths.sorted(by: { $0 < $1 }) {
                    let url = source.appending(path: relPath).standardizedFileURL
                    guard let info = closure(url) else {
                        continue
                    }
                    entryInfo.append(info)
                }
            }
            try Self._compressEntries(
                entryInfo,
                destination: destination,
                writerConfiguration: writerConfiguration,
                hasher: &hasher
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return hasher.finalize()
    }

    public static func compress(
        entries: [ArchiveEntryInfo],
        destination: URL,
        writerConfiguration: ArchiveWriterConfiguration = ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip)
    ) throws -> SHA256.Digest {
        let destination = destination.standardizedFileURL
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)

        var hasher = SHA256()

        do {
            let directory = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self._compressEntries(
                entries,
                destination: destination,
                writerConfiguration: writerConfiguration,
                hasher: &hasher
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return hasher.finalize()
    }

    public static func uncompress(source: URL, destination: URL) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL

        // TODO: ArchiveReader needs some enhancement to support buffered uncompression
        let reader = try ArchiveReader(
            format: .paxRestricted,
            filter: .gzip,
            file: source
        )

        for (entry, data) in reader {
            guard let path = entry.path else {
                continue
            }
            let uncompressPath = destination.appendingPathComponent(path)

            let fileManager = FileManager.default
            switch entry.fileType {
            case .blockSpecial, .characterSpecial, .socket:
                continue
            case .directory:
                try fileManager.createDirectory(
                    at: uncompressPath,
                    withIntermediateDirectories: true,
                    attributes: [
                        FileAttributeKey.posixPermissions: entry.permissions
                    ]
                )
            case .regular:
                try fileManager.createDirectory(
                    at: uncompressPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [
                        FileAttributeKey.posixPermissions: 0o755
                    ]
                )
                let success = fileManager.createFile(
                    atPath: uncompressPath.path,
                    contents: data,
                    attributes: [
                        FileAttributeKey.posixPermissions: entry.permissions
                    ]
                )
                if !success {
                    throw POSIXError.fromErrno()
                }
                try data.write(to: uncompressPath)
            case .symbolicLink:
                guard let target = entry.symlinkTarget else {
                    continue
                }
                try fileManager.createDirectory(
                    at: uncompressPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [
                        FileAttributeKey.posixPermissions: 0o755
                    ]
                )
                try fileManager.createSymbolicLink(atPath: uncompressPath.path, withDestinationPath: target)
                continue
            default:
                continue
            }

            // FIXME: uid/gid for compress.
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: entry.permissions)],
                ofItemAtPath: uncompressPath.path
            )

            if let creationDate = entry.creationDate {
                try fileManager.setAttributes(
                    [.creationDate: creationDate],
                    ofItemAtPath: uncompressPath.path
                )
            }

            if let modificationDate = entry.modificationDate {
                try fileManager.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: uncompressPath.path
                )
            }
        }
    }

    // MARK: private functions
    private static func _compressEntries(
        _ entryInfo: [ArchiveEntryInfo],
        destination: URL,
        writerConfiguration: ArchiveWriterConfiguration,
        hasher: inout SHA256
    ) throws {
        let archivedPathsByHostPath = entryInfo.reduce(into: [String: [URL]]()) { result, info in
            result[info.pathOnHost.path, default: []].append(info.pathInArchive)
        }

        let archiver = try ArchiveWriter(configuration: writerConfiguration)
        try archiver.open(file: destination)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        for info in entryInfo {
            guard let entry = try Self._createEntry(entryInfo: info, archivedPathsByHostPath: archivedPathsByHostPath) else {
                throw Error.failedToCreateEntry
            }
            let hashInfo = ArchiveEntryHashInfo(
                pathOnHost: info.pathOnHost.path,
                pathInArchive: info.pathInArchive.relativePath,
                owner: info.owner,
                group: info.group,
                permissions: info.permissions,
                fileType: entry.fileType.rawValue,
                symlinkTarget: entry.symlinkTarget,
                size: entry.size
            )
            hasher.update(data: try encoder.encode(hashInfo))
            try Self._compressFile(itemPath: info.pathOnHost.path, entry: entry, archiver: archiver, hasher: &hasher)
        }
        try archiver.finishEncoding()
    }

    private static func _compressFile(itemPath: String, entry: WriteEntry, archiver: ArchiveWriter, hasher: inout SHA256) throws {
        guard entry.fileType == .regular else {
            let writer = archiver.makeTransactionWriter()
            try writer.writeHeader(entry: entry)
            try writer.finish()
            return
        }

        let writer = archiver.makeTransactionWriter()

        let bufferSize = Int(1.mib())
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { readBuffer.deallocate() }

        try writer.writeHeader(entry: entry)
        try itemPath.withCString { fileSystemPath in
            let fd = open(fileSystemPath, O_RDONLY)
            guard fd >= 0 else {
                throw POSIXError.fromErrno()
            }
            defer { close(fd) }

            while true {
                let bytesRead = read(fd, readBuffer, bufferSize)
                if bytesRead < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError.fromErrno()
                }
                if bytesRead == 0 {
                    break
                }

                let data = Data(bytesNoCopy: readBuffer, count: bytesRead, deallocator: .none)
                hasher.update(data: data)
                try data.withUnsafeBytes { pointer in
                    try writer.writeChunk(data: pointer)
                }
            }
        }
        try writer.finish()
    }

    private static func _createEntry(
        entryInfo: ArchiveEntryInfo,
        archivedPathsByHostPath: [String: [URL]] = [:],
        pathPrefix: String = ""
    ) throws -> WriteEntry? {
        let entry = WriteEntry()
        let hostPath = entryInfo.pathOnHost.path
        let status = try Self._fileStatus(atPath: hostPath)

        switch status.entryType {
        case .directory:
            entry.fileType = .directory
            entry.size = 0
        case .regular:
            entry.fileType = .regular
            entry.size = status.size
        case .symbolicLink:
            entry.fileType = .symbolicLink
            entry.size = 0
            entry.symlinkTarget = Self._rewriteArchivedAbsoluteSymlinkTarget(
                status.symlinkTarget ?? "",
                entryInfo: entryInfo,
                archivedPathsByHostPath: archivedPathsByHostPath
            )
        }

        #if os(macOS)
        entry.permissions = status.permissions
        #else
        entry.permissions = UInt32(status.permissions)
        #endif
        entry.owner = status.owner
        entry.group = status.group
        entry.creationDate = status.creationDate
        entry.modificationDate = status.modificationDate

        // Apply explicit overrides from ArchiveEntryInfo when provided
        if let overrideOwner = entryInfo.owner {
            entry.owner = overrideOwner
        }
        if let overrideGroup = entryInfo.group {
            entry.group = overrideGroup
        }
        if let overridePerm = entryInfo.permissions {
            #if os(macOS)
            entry.permissions = overridePerm
            #else
            entry.permissions = UInt32(overridePerm)
            #endif
        }

        let pathTrimmed = Self._trimPathPrefix(entryInfo.pathInArchive.relativePath, pathPrefix: pathPrefix)
        entry.path = pathTrimmed
        return entry
    }

    private static func _fileStatus(atPath path: String) throws -> FileStatus {
        try path.withCString { fileSystemPath in
            var status = stat()
            guard lstat(fileSystemPath, &status) == 0 else {
                throw POSIXError.fromErrno()
            }

            let mode = status.st_mode & S_IFMT
            let entryType: FileStatus.EntryType
            let symlinkTarget: String?

            switch mode {
            case S_IFDIR:
                entryType = .directory
                symlinkTarget = nil
            case S_IFREG:
                entryType = .regular
                symlinkTarget = nil
            case S_IFLNK:
                entryType = .symbolicLink
                symlinkTarget = try Self._symlinkTarget(fileSystemPath: fileSystemPath, sizeHint: Int(status.st_size))
            default:
                throw Error.failedToCreateEntry
            }

            return FileStatus(
                entryType: entryType,
                permissions: UInt16(status.st_mode & 0o7777),
                size: Int64(status.st_size),
                owner: status.st_uid,
                group: status.st_gid,
                creationDate: Self._creationDate(from: status),
                modificationDate: Self._modificationDate(from: status),
                symlinkTarget: symlinkTarget
            )
        }
    }

    private static func _symlinkTarget(fileSystemPath: UnsafePointer<CChar>, sizeHint: Int) throws -> String {
        let capacity = max(sizeHint + 1, Int(PATH_MAX))
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let count = readlink(fileSystemPath, buffer, capacity - 1)
        guard count >= 0 else {
            throw POSIXError.fromErrno()
        }

        buffer[count] = 0
        return String(cString: buffer)
    }

    private static func _creationDate(from status: stat) -> Date? {
        #if os(macOS)
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_birthtimespec.tv_sec)
                + TimeInterval(status.st_birthtimespec.tv_nsec) / 1_000_000_000
        )
        #else
        return nil
        #endif
    }

    private static func _modificationDate(from status: stat) -> Date? {
        #if os(macOS)
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        #else
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_mtim.tv_sec)
                + TimeInterval(status.st_mtim.tv_nsec) / 1_000_000_000
        )
        #endif
    }

    private static func _trimPathPrefix(_ path: String, pathPrefix: String) -> String {
        guard !path.isEmpty && !pathPrefix.isEmpty else {
            return path
        }

        let decodedPath = path.removingPercentEncoding ?? path

        guard decodedPath.hasPrefix(pathPrefix) else {
            return decodedPath
        }
        let trimmedPath = String(decodedPath.suffix(from: pathPrefix.endIndex))
        return trimmedPath
    }

    private static func _rewriteArchivedAbsoluteSymlinkTarget(
        _ symlinkTarget: String,
        entryInfo: ArchiveEntryInfo,
        archivedPathsByHostPath: [String: [URL]]
    ) -> String {
        guard symlinkTarget.hasPrefix("/") else {
            return symlinkTarget
        }

        let targetPath = URL(fileURLWithPath: symlinkTarget)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard let targetArchivePaths = archivedPathsByHostPath[targetPath], targetArchivePaths.count == 1, let targetArchivePath = targetArchivePaths.first else {
            return symlinkTarget
        }

        let sourceDirectory = entryInfo.pathInArchive.deletingLastPathComponent().relativePath
        return Self._relativeArchivePath(fromDirectory: sourceDirectory, to: targetArchivePath.relativePath)
    }

    private static func _relativeArchivePath(fromDirectory: String, to path: String) -> String {
        let fromComponents = Self._archivePathComponents(fromDirectory)
        let toComponents = Self._archivePathComponents(path)

        var commonPrefixCount = 0
        while commonPrefixCount < fromComponents.count,
            commonPrefixCount < toComponents.count,
            fromComponents[commonPrefixCount] == toComponents[commonPrefixCount]
        {
            commonPrefixCount += 1
        }

        let upwardTraversal = Array(repeating: "..", count: fromComponents.count - commonPrefixCount)
        let remainder = Array(toComponents.dropFirst(commonPrefixCount))
        let relativeComponents = upwardTraversal + remainder
        return relativeComponents.isEmpty ? "." : relativeComponents.joined(separator: "/")
    }

    private static func _archivePathComponents(_ path: String) -> [String] {
        NSString(string: path).pathComponents.filter { component in
            component != "/" && component != "."
        }
    }

    private static func _isSymbolicLink(_ path: URL) throws -> Bool {
        let resourceValues = try path.resourceValues(forKeys: [.isSymbolicLinkKey])
        if let isSymbolicLink = resourceValues.isSymbolicLink {
            if isSymbolicLink {
                return true
            }
        }
        return false
    }
}

extension Archiver {
    public enum Error: Swift.Error, CustomStringConvertible {
        case failedToCreateEntry
        case fileDoesNotExist(_ url: URL)

        public var description: String {
            switch self {
            case .failedToCreateEntry:
                return "failed to create entry"
            case .fileDoesNotExist(let url):
                return "file \(url.path) does not exist"
            }
        }
    }
}
