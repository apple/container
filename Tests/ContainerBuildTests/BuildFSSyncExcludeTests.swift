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

import ContainerAPIClient
import ContainerizationArchive
import Foundation
import Testing

@testable import ContainerBuild

// Tests for how walk() builds the context tar: it archives exactly the paths it
// resolved, and leaves out the paths forwarded `.dockerignore` patterns exclude
// without reading them (apple/container#2444).
@Suite class BuildFSSyncExcludeTests {
    let fm = FileManager.default
    let base: URL
    let contextDir: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        contextDir = base.appendingPathComponent("context")
        try fm.createDirectory(at: contextDir, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions so the unreadable fixtures can be removed.
        if let paths = fm.enumerator(atPath: base.path) {
            for case let path as String in paths {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(path).path)
            }
        }
        try? fm.removeItem(at: base)
    }

    // MARK: - Helpers

    private func file(_ relative: String, _ content: String = "x", permissions: Int? = nil) throws {
        let url = contextDir.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    private func dir(_ relative: String) throws {
        try fm.createDirectory(at: contextDir.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    private func walkPacket(followPaths: [String], excludes: [String]?, mode: String) -> BuildTransfer {
        var p = BuildTransfer()
        p.id = UUID().uuidString
        p.source = "."
        p.metadata = [
            "followpaths": followPaths.joined(separator: ","),
            "mode": mode,
        ]
        if let excludes {
            p.metadata["exclude-patterns"] = excludes.map {
                $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0
            }.joined(separator: ",")
            p.metadata["exclude-patterns-encoded"] = "1"
        }
        return p
    }

    /// Runs a tar-mode walk and returns the archive's entry paths, in archive order.
    private func walkTar(followPaths: [String] = ["."], excludes: [String]? = nil) async throws -> [String] {
        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        let stream = AsyncStream<ClientStream> { continuation = $0 }
        try await fssync.walk(continuation, walkPacket(followPaths: followPaths, excludes: excludes, mode: "tar"), "build-0")
        continuation.finish()

        var tar = Data()
        for await resp in stream {
            tar.append(resp.buildTransfer.data)
        }
        let tarURL = base.appendingPathComponent(UUID().uuidString + ".tar")
        try tar.write(to: tarURL)
        return try ArchiveReader(file: tarURL).map { entry, _ in entry.path ?? "" }
    }

    /// Runs a JSON-mode walk and returns the reported names.
    private func walkJSON(followPaths: [String] = ["."], excludes: [String]? = nil) async throws -> Set<String> {
        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        let stream = AsyncStream<ClientStream> { continuation = $0 }
        try await fssync.walk(continuation, walkPacket(followPaths: followPaths, excludes: excludes, mode: "json"), "build-0")
        continuation.finish()

        var names = Set<String>()
        for await resp in stream where !resp.buildTransfer.data.isEmpty {
            names.formUnion(try JSONDecoder().decode([BuildFSSync.FileInfo].self, from: resp.buildTransfer.data).map(\.name))
        }
        return names
    }

    private func normalized(_ paths: [String]) -> Set<String> {
        Set(paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
    }

    // MARK: - Excludes

    @Test func testExcludedDirectoryIsNeitherArchivedNorRead() async throws {
        try file("keep")
        try file("Dockerfile")
        try file("ignored/blob1")
        // Reading this file fails, so the walk only succeeds if the host never reads it.
        try file("ignored/sub/unreadable", permissions: 0o000)

        let entries = normalized(try await walkTar(excludes: ["ignored"]))

        #expect(entries == ["keep", "Dockerfile"])
    }

    @Test func testWithoutExcludesEverythingIsArchivedAsBefore() async throws {
        try file("keep")
        try file("ignored/blob1")
        try file("ignored/sub/blob2")

        let entries = normalized(try await walkTar())

        #expect(entries == ["keep", "ignored", "ignored/blob1", "ignored/sub", "ignored/sub/blob2"])
    }

    @Test func testUnencodedExcludesAreIgnored() async throws {
        try file("keep")
        try file("ignored/blob1")
        var p = walkPacket(followPaths: ["."], excludes: nil, mode: "json")
        p.metadata["exclude-patterns"] = "ignored"

        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        let stream = AsyncStream<ClientStream> { continuation = $0 }
        try await fssync.walk(continuation, p, "build-0")
        continuation.finish()
        var names = Set<String>()
        for await resp in stream where !resp.buildTransfer.data.isEmpty {
            names.formUnion(try JSONDecoder().decode([BuildFSSync.FileInfo].self, from: resp.buildTransfer.data).map(\.name))
        }

        #expect(names.contains("ignored/blob1"))
    }

    @Test func testNegationKeepsFileAndItsParentDirectory() async throws {
        try file("ignored/keep")
        try file("ignored/blob1")
        try file("other")

        let names = try await walkJSON(excludes: ["ignored", "!ignored/keep"])

        // The shim does the exact filtering; the host must only keep what a negation might need.
        #expect(names.contains("ignored"))
        #expect(names.contains("ignored/keep"))
        #expect(names.contains("other"))
    }

    @Test func testNestedPatternsAndWildcards() async throws {
        try file("src/main.rs")
        try file("src/debug.log")
        try file("target/debug/app", permissions: 0o000)
        try file("crates/a/target/out", permissions: 0o000)
        try file("crates/a/lib.rs")

        let entries = normalized(try await walkTar(excludes: ["**/target", "**/*.log"]))

        #expect(entries == ["src", "src/main.rs", "crates", "crates/a", "crates/a/lib.rs"])
    }

    @Test func testCopySubdirectoryAppliesExcludesInside() async throws {
        try file("app/main.swift")
        try file("app/.build/cache", permissions: 0o000)
        try file("other/file")

        let entries = normalized(try await walkTar(followPaths: ["app"], excludes: ["app/.build"]))

        #expect(entries == ["app", "app/main.swift"])
    }

    @Test func testEmptyDirectories() async throws {
        try dir("empty-kept")
        try dir("empty-ignored")
        try file("keep")

        let names = try await walkJSON(excludes: ["empty-ignored"])

        #expect(names.contains("empty-kept"))
        #expect(!names.contains("empty-ignored"))
    }

    @Test func testSymlinkToExcludedTargetIsKeptButTargetIsNot() async throws {
        try file("ignored/real", permissions: 0o000)
        try fm.createSymbolicLink(atPath: contextDir.appendingPathComponent("link").path, withDestinationPath: "ignored/real")

        let entries = normalized(try await walkTar(excludes: ["ignored"]))

        #expect(entries == ["link"])
    }

    @Test func testExcludedSymlinkToKeptTarget() async throws {
        try file("real")
        try fm.createSymbolicLink(atPath: contextDir.appendingPathComponent("link").path, withDestinationPath: "real")

        let entries = normalized(try await walkTar(excludes: ["link"]))

        #expect(entries == ["real"])
    }

    @Test func testDirectorySymlinkInsideExcludedDirectoryIsNotFollowed() async throws {
        try file("data/blob", permissions: 0o000)
        try dir("ignored")
        try fm.createSymbolicLink(atPath: contextDir.appendingPathComponent("ignored/data").path, withDestinationPath: "../data")
        try file("keep")

        // Without pruning, "ignored/data" would be found and its target "data" added next to it.
        let entries = normalized(try await walkTar(followPaths: ["keep", "ignored"], excludes: ["ignored"]))

        #expect(entries == ["keep"])
    }

    // MARK: - Archive contents

    @Test func testInContextSymlinkTargetWithoutParentEntryIsArchived() async throws {
        try file("real/x")
        try file("real/y")
        try fm.createSymbolicLink(atPath: contextDir.appendingPathComponent("link").path, withDestinationPath: "real/x")

        let entries = normalized(try await walkTar(followPaths: ["link"]))

        // The target is archived next to the link even though "real" itself was not requested.
        #expect(entries == ["link", "real/x"])
    }

    @Test func testArchiveOrderIsSortedByFullPath() async throws {
        try file("a/b")
        try file("a-c")
        try file("a.d")

        let entries = try await walkTar().map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }

        #expect(entries == entries.sorted(by: <))
    }

    @Test func testEntriesOverloadMatchesClosureOverload() throws {
        try file("a/b", "one")
        try file("a-c", "two")
        try file("z")
        try fm.createSymbolicLink(atPath: contextDir.appendingPathComponent("link").path, withDestinationPath: "a/b")

        let source = contextDir.standardizedFileURL
        let config = ArchiveWriterConfiguration(format: .paxRestricted, filter: .none)
        var collected: [Archiver.ArchiveEntryInfo] = []
        let viaClosure = try Archiver.compress(
            source: source, destination: base.appendingPathComponent("closure.tar"), writerConfiguration: config
        ) { url in
            guard let rel = try? url.relativeChildPath(to: source), rel != "z" else { return nil }
            let info = Archiver.ArchiveEntryInfo(pathOnHost: url, pathInArchive: URL(fileURLWithPath: rel))
            collected.append(info)
            return info
        }
        let viaEntries = try Archiver.compress(
            entries: collected, destination: base.appendingPathComponent("entries.tar"), writerConfiguration: config)

        #expect(viaClosure == viaEntries)
    }
}
