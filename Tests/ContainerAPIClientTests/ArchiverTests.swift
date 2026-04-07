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

import Foundation
import Testing

import ContainerizationArchive

@testable import ContainerAPIClient

struct ArchiverTests {
    private enum EntryType {
        case regular(String)
        case directory
        case symlink(String)
    }

    private func createTestArchive(
        name: String,
        entries: [(path: String, type: EntryType)],
        baseDirectory: URL
    ) throws -> URL {
        let archiveURL = baseDirectory.appendingPathComponent("\(name).tar.gz")
        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .gzip, file: archiveURL)

        for entry in entries {
            let writeEntry = WriteEntry()
            writeEntry.path = entry.path
            writeEntry.permissions = 0o644
            writeEntry.owner = 1000
            writeEntry.group = 1000

            switch entry.type {
            case .regular(let content):
                writeEntry.fileType = .regular
                let data = try #require(content.data(using: .utf8))
                writeEntry.size = numericCast(data.count)
                try archiver.writeEntry(entry: writeEntry, data: data)
            case .directory:
                writeEntry.fileType = .directory
                writeEntry.permissions = 0o755
                writeEntry.size = 0
                try archiver.writeEntry(entry: writeEntry, data: nil)
            case .symlink(let target):
                writeEntry.fileType = .symbolicLink
                writeEntry.symlinkTarget = target
                writeEntry.size = 0
                try archiver.writeEntry(entry: writeEntry, data: nil)
            }
        }

        try archiver.finishEncoding()
        return archiveURL
    }

    @Test
    func testCompressAndUncompressPreservesRelativeSymbolicLink() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        let archiveURL = tempURL.appendingPathComponent("archive.tar.gz")
        let destinationURL = tempURL.appendingPathComponent("destination")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let targetURL = sourceURL.appendingPathComponent("target.txt")
        try #require("hello".data(using: .utf8)).write(to: targetURL)
        let linkURL = sourceURL.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "target.txt")

        _ = try Archiver.compress(source: sourceURL, destination: archiveURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        try Archiver.uncompress(source: archiveURL, destination: destinationURL)

        let extractedLinkURL = destinationURL.appendingPathComponent("link.txt")
        let values = try extractedLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: extractedLinkURL.path) == "target.txt")
        #expect(try String(contentsOf: destinationURL.appendingPathComponent("target.txt"), encoding: .utf8) == "hello")
    }

    @Test
    func testCompressAndUncompressPreservesAbsoluteSymbolicLink() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        let archiveURL = tempURL.appendingPathComponent("archive.tar.gz")
        let destinationURL = tempURL.appendingPathComponent("destination")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let externalTargetURL = tempURL.appendingPathComponent("external-target.txt")
        try #require("external".data(using: .utf8)).write(to: externalTargetURL)
        let linkURL = sourceURL.appendingPathComponent("absolute-link.txt")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: externalTargetURL.path)

        _ = try Archiver.compress(source: sourceURL, destination: archiveURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        try Archiver.uncompress(source: archiveURL, destination: destinationURL)

        let extractedLinkURL = destinationURL.appendingPathComponent("absolute-link.txt")
        let values = try extractedLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: extractedLinkURL.path) == externalTargetURL.path)
    }

    @Test
    func testCompressAndUncompressPreservesInternalAbsoluteSymbolicLinkTarget() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        let archiveURL = tempURL.appendingPathComponent("archive.tar.gz")
        let destinationURL = tempURL.appendingPathComponent("destination")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let targetURL = sourceURL.appendingPathComponent("target.txt")
        try #require("hello".data(using: .utf8)).write(to: targetURL)
        let linkURL = sourceURL.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: targetURL.path)

        _ = try Archiver.compress(source: sourceURL, destination: archiveURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        try Archiver.uncompress(source: archiveURL, destination: destinationURL)

        let extractedLinkURL = destinationURL.appendingPathComponent("link.txt")
        let values = try extractedLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: extractedLinkURL.path) == targetURL.path)
        #expect(try String(contentsOf: extractedLinkURL, encoding: .utf8) == "hello")
    }

    @Test
    func testCompressAndUncompressPreservesAbsoluteSymbolicLinkTargetThroughSymlinkedAncestor() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        let archiveURL = tempURL.appendingPathComponent("archive.tar.gz")
        let destinationURL = tempURL.appendingPathComponent("destination")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let realDirectoryURL = sourceURL.appendingPathComponent("real")
        try fileManager.createDirectory(at: realDirectoryURL, withIntermediateDirectories: true)
        let targetURL = realDirectoryURL.appendingPathComponent("target.txt")
        try #require("hello".data(using: .utf8)).write(to: targetURL)

        let aliasURL = sourceURL.appendingPathComponent("alias")
        try fileManager.createSymbolicLink(atPath: aliasURL.path, withDestinationPath: "real")

        let linkURL = sourceURL.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: sourceURL.appendingPathComponent("alias/target.txt").path
        )

        _ = try Archiver.compress(source: sourceURL, destination: archiveURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        try Archiver.uncompress(source: archiveURL, destination: destinationURL)

        let extractedLinkURL = destinationURL.appendingPathComponent("link.txt")
        let values = try extractedLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(
            try fileManager.destinationOfSymbolicLink(atPath: extractedLinkURL.path)
                == sourceURL.appendingPathComponent("alias/target.txt").path
        )
        #expect(try String(contentsOf: extractedLinkURL, encoding: .utf8) == "hello")
    }

    @Test
    func testCompressDigestChangesWhenSymlinkTargetChanges() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let firstTargetURL = sourceURL.appendingPathComponent("first.txt")
        let secondTargetURL = sourceURL.appendingPathComponent("second.txt")
        try #require("first".data(using: .utf8)).write(to: firstTargetURL)
        try #require("second".data(using: .utf8)).write(to: secondTargetURL)

        let linkURL = sourceURL.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "first.txt")

        let firstArchiveURL = tempURL.appendingPathComponent("first.tar.gz")
        let firstDigest = try archiveDigest(sourceURL: sourceURL, destinationURL: firstArchiveURL)

        try fileManager.removeItem(at: linkURL)
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "second.txt")

        let secondArchiveURL = tempURL.appendingPathComponent("second.tar.gz")
        let secondDigest = try archiveDigest(sourceURL: sourceURL, destinationURL: secondArchiveURL)

        #expect(firstDigest != secondDigest)
    }

    @Test
    func testCompressEntriesOnlyArchivesExplicitInputs() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        let archiveURL = tempURL.appendingPathComponent("archive.tar.gz")
        let destinationURL = tempURL.appendingPathComponent("destination")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let includeURL = sourceURL.appendingPathComponent("include.txt")
        let excludeURL = sourceURL.appendingPathComponent("exclude.txt")
        try #require("keep".data(using: .utf8)).write(to: includeURL)
        try #require("drop".data(using: .utf8)).write(to: excludeURL)

        _ = try Archiver.compress(
            entries: [
                Archiver.ArchiveEntryInfo(
                    pathOnHost: includeURL,
                    pathInArchive: URL(fileURLWithPath: "include.txt")
                )
            ],
            destination: archiveURL
        )

        try Archiver.uncompress(source: archiveURL, destination: destinationURL)

        #expect(fileManager.fileExists(atPath: destinationURL.appendingPathComponent("include.txt").path))
        #expect(!fileManager.fileExists(atPath: destinationURL.appendingPathComponent("exclude.txt").path))
    }

    @Test
    func testUncompressRejectsPathTraversalMembers() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let archiveURL = try createTestArchive(
            name: "traversal",
            entries: [
                (path: "safe.txt", type: .regular("safe")),
                (path: "../outside.txt", type: .regular("evil")),
            ],
            baseDirectory: tempURL
        )
        let destinationURL = tempURL.appendingPathComponent("destination")

        #expect(throws: Archiver.Error.rejectedArchiveMembers(["../outside.txt"])) {
            try Archiver.uncompress(source: archiveURL, destination: destinationURL)
        }

        #expect(fileManager.fileExists(atPath: destinationURL.appendingPathComponent("safe.txt").path))
        #expect(!fileManager.fileExists(atPath: tempURL.appendingPathComponent("outside.txt").path))
    }

    private func archiveDigest(sourceURL: URL, destinationURL: URL) throws -> String {
        let digest = try Archiver.compress(source: sourceURL, destination: destinationURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
