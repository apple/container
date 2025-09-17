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

import ContainerizationArchive
import ContainerizationOS
import Foundation

public final class Archiver: Sendable {
    public struct ArchiveEntryInfo: Sendable {
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

    public static func compress(
        source: URL,
        destination: URL,
        followSymlinks: Bool = false,
        writerConfiguration: ArchiveWriterConfiguration = ArchiveWriterConfiguration(format: .paxRestricted, filter: .gzip),
        closure: (URL) -> ArchiveEntryInfo?
    ) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)

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
                while let relPath = enumerator.nextObject() as? String {
                    let url = source.appending(path: relPath).standardizedFileURL
                    guard let info = closure(url) else {
                        continue
                    }
                    entryInfo.append(info)
                }
            }

            let archiver = try ArchiveWriter(
                configuration: writerConfiguration
            )
            try archiver.open(file: destination)

            for info in entryInfo {
                guard let entry = try Self._createEntry(entryInfo: info) else {
                    throw Error.failedToCreateEntry
                }
                try Self._compressFile(item: info.pathOnHost, entry: entry, archiver: archiver)
            }
            try archiver.finishEncoding()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
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
    private static func _compressFile(item: URL, entry: WriteEntry, archiver: ArchiveWriter) throws {
        guard let stream = InputStream(url: item) else {
            return
        }

        let writer = archiver.makeTransactionWriter()

        let bufferSize = Int(1.mib())
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

        stream.open()
        try writer.writeHeader(entry: entry)
        while true {
            let byteRead = stream.read(readBuffer, maxLength: bufferSize)
            if byteRead <= 0 {
                break
            } else {
                let data = Data(bytes: readBuffer, count: byteRead)
                try data.withUnsafeBytes { pointer in
                    try writer.writeChunk(data: pointer)
                }
            }
        }
        stream.close()
        try writer.finish()
    }

    private static func _createEntry(entryInfo: ArchiveEntryInfo, pathPrefix: String = "") throws -> WriteEntry? {
        let entry = WriteEntry()
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: entryInfo.pathOnHost.path)

        if let fileType = attributes[.type] as? FileAttributeType {
            switch fileType {
            case .typeBlockSpecial, .typeCharacterSpecial, .typeSocket:
                return nil
            case .typeDirectory:
                entry.fileType = .directory
            case .typeRegular:
                entry.fileType = .regular
            case .typeSymbolicLink:
                entry.fileType = .symbolicLink
                let symlinkTarget = try fileManager.destinationOfSymbolicLink(atPath: entryInfo.pathOnHost.path)
                entry.symlinkTarget = symlinkTarget
            default:
                return nil
            }
        }
        if let posixPermissions = attributes[.posixPermissions] as? NSNumber {
            #if os(macOS)
            entry.permissions = posixPermissions.uint16Value
            #else
            entry.permissions = posixPermissions.uint32Value
            #endif
        }
        if let fileSize = attributes[.size] as? UInt64 {
            entry.size = Int64(fileSize)
        }
        if let uid = attributes[.ownerAccountID] as? NSNumber {
            entry.owner = uid.uint32Value
        }
        if let gid = attributes[.groupOwnerAccountID] as? NSNumber {
            entry.group = gid.uint32Value
        }
        if let creationDate = attributes[.creationDate] as? Date {
            entry.creationDate = creationDate
        }
        if let modificationDate = attributes[.modificationDate] as? Date {
            entry.modificationDate = modificationDate
        }

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
