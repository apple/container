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
import Foundation

public final class Archiver: Sendable {
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

            let archiver = try ArchiveWriter(
                configuration: writerConfiguration
            )
            try archiver.open(file: destination)

            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys

            for info in entryInfo {
                guard let entry = try Self._createEntry(entryInfo: info) else {
                    throw Error.failedToCreateEntry
                }
                hasher.update(data: try encoder.encode(entry))
                try Self._compressFile(item: info.pathOnHost, entry: entry, archiver: archiver, hasher: &hasher)
            }
            try archiver.finishEncoding()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return hasher.finalize()
    }

    // MARK: private functions
    private static func _compressFile(item: URL, entry: WriteEntry, archiver: ArchiveWriter, hasher: inout SHA256) throws {
        let writer = archiver.makeTransactionWriter()
        let bufferSize = Int(1.mib())
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        try writer.writeHeader(entry: entry)
        if entry.fileType == .regular {
            // We need to write the data into the archive only if its a regular file
            // Symlinks and directories require us to only write the archive header
            guard let stream = InputStream(url: item) else {
                throw Error.failedToCreateInputStream(item)
            }
            stream.open()
            while true {
                let byteRead = stream.read(readBuffer, maxLength: bufferSize)
                if byteRead <= 0 {
                    break
                } else {
                    let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: readBuffer), count: byteRead, deallocator: .none)
                    hasher.update(data: data)
                    try data.withUnsafeBytes { pointer in
                        try writer.writeChunk(data: pointer)
                    }
                }
            }
            stream.close()
        }
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
}

extension Archiver {
    public enum Error: Swift.Error, CustomStringConvertible {
        case failedToCreateEntry
        case fileDoesNotExist(_ url: URL)
        case failedToCreateInputStream(_ url: URL)

        public var description: String {
            switch self {
            case .failedToCreateEntry:
                return "failed to create entry"
            case .fileDoesNotExist(let url):
                return "file \(url.path) does not exist"
            case .failedToCreateInputStream(let url):
                return "failed to create input stream for \(url.path)"
            }
        }
    }
}

extension WriteEntry: @retroactive Encodable {
    enum CodingKeys: String, CodingKey {
        case path
        case fileType
        case size
        case permissions
        case owner
        case group
        case symlinkTarget
        case hardlink
        case creationDate
        case modificationDate
        case contentAccessDate
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fileType.rawValue, forKey: .fileType)
        try container.encodeIfPresent(permissions, forKey: .permissions)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encodeIfPresent(symlinkTarget, forKey: .symlinkTarget)
        try container.encodeIfPresent(hardlink, forKey: .hardlink)
        try container.encodeIfPresent(creationDate, forKey: .creationDate)
        try container.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try container.encodeIfPresent(contentAccessDate, forKey: .contentAccessDate)
    }
}
