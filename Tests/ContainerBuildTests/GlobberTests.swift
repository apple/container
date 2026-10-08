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

import ContainerizationOS
import Foundation
import Testing

@testable import ContainerBuild

struct TestCase {
    let pattern: String
    let fileName: String
    let expectSuccess: Bool
}

// test cases adapted from https://github.com/moby/patternmatcher/tree/main
let globTestCases = [
    TestCase(pattern: "*", fileName: "test.go", expectSuccess: true),
    TestCase(pattern: "**", fileName: "test.go", expectSuccess: true),
    TestCase(pattern: "**", fileName: "file", expectSuccess: true),
    TestCase(pattern: "*.go", fileName: "test.go", expectSuccess: true),
    TestCase(pattern: "a.|)$(}+{bc", fileName: "a.|)$(}+{bc", expectSuccess: true),
    TestCase(pattern: "abc.def", fileName: "abcdef", expectSuccess: false),
    TestCase(pattern: "abc.def", fileName: "abc.def", expectSuccess: true),
    TestCase(pattern: "abc.def", fileName: "abcZdef", expectSuccess: false),
    TestCase(pattern: "abc?def", fileName: "abcZdef", expectSuccess: true),
    TestCase(pattern: "abc?def", fileName: "abcdef", expectSuccess: false),
    TestCase(pattern: "a[b-d]e", fileName: "ae", expectSuccess: false),
    TestCase(pattern: "a[b-d]e", fileName: "ace", expectSuccess: true),
    TestCase(pattern: "a[b-d]e", fileName: "aae", expectSuccess: false),
    TestCase(pattern: "a[^b-d]e", fileName: "aze", expectSuccess: true),
    TestCase(pattern: "a[\\^b-d]e", fileName: "abe", expectSuccess: true),
    TestCase(pattern: "a[\\^b-d]e", fileName: "aze", expectSuccess: false),
]

let errorGlobTestCases = [
    TestCase(pattern: "[]a]", fileName: "]", expectSuccess: true),
    TestCase(pattern: "[", fileName: "a", expectSuccess: true),
    TestCase(pattern: "[^", fileName: "a", expectSuccess: true),
    TestCase(pattern: "[^bc", fileName: "a", expectSuccess: true),
    TestCase(pattern: "a[", fileName: "a", expectSuccess: true),
    TestCase(pattern: "a[", fileName: "ab", expectSuccess: true),
]

let testCases = [
    TestCase(pattern: "*", fileName: "test/test.go", expectSuccess: true),
    TestCase(pattern: "**.go", fileName: "test/test.go", expectSuccess: true),
    TestCase(pattern: "**file", fileName: "test/file", expectSuccess: true),
    TestCase(pattern: "**/*", fileName: "test/test.go", expectSuccess: true),
    TestCase(pattern: "**/", fileName: "file", expectSuccess: true),
    TestCase(pattern: "**/", fileName: "file/", expectSuccess: true),
    TestCase(pattern: "**", fileName: "file", expectSuccess: true),
    TestCase(pattern: "**", fileName: "file/", expectSuccess: true),
    TestCase(pattern: "**", fileName: "dir/file", expectSuccess: true),
    TestCase(pattern: "**/", fileName: "dir/file", expectSuccess: true),
    TestCase(pattern: "**", fileName: "dir/file/", expectSuccess: true),
    TestCase(pattern: "**/", fileName: "dir/file/", expectSuccess: true),
    TestCase(pattern: "**/**", fileName: "dir/file", expectSuccess: true),
    TestCase(pattern: "**/**", fileName: "dir/file/", expectSuccess: true),
    TestCase(pattern: "dir/**", fileName: "dir/file", expectSuccess: true),
    TestCase(pattern: "dir/**", fileName: "dir/file/", expectSuccess: true),
    TestCase(pattern: "dir/**", fileName: "dir/dir2/file", expectSuccess: true),
    TestCase(pattern: "dir/**", fileName: "dir/dir2/file/", expectSuccess: true),
    TestCase(pattern: "**/dir", fileName: "dir", expectSuccess: true),
    TestCase(pattern: "**/dir", fileName: "dir/file", expectSuccess: true),
    TestCase(pattern: "**/dir2/*", fileName: "dir/dir2/file", expectSuccess: true),
    TestCase(pattern: "**/dir2/*", fileName: "dir/dir2/file/", expectSuccess: true),
    TestCase(pattern: "**/dir2/**", fileName: "dir/dir2/dir3/file", expectSuccess: true),
    TestCase(pattern: "**/dir2/**", fileName: "dir/dir2/dir3/file/", expectSuccess: true),
    TestCase(pattern: "**file", fileName: "file", expectSuccess: true),
    TestCase(pattern: "**file", fileName: "dir/file", expectSuccess: true),
    TestCase(pattern: "**/file", fileName: "dir/file", expectSuccess: true),
    TestCase(pattern: "**file", fileName: "dir/dir/file", expectSuccess: true),
    TestCase(pattern: "**/file", fileName: "dir/dir/file", expectSuccess: true),
    TestCase(pattern: "**/file*", fileName: "dir/dir/file", expectSuccess: true),
    TestCase(pattern: "**/file*", fileName: "dir/dir/file.txt", expectSuccess: true),
    TestCase(pattern: "**/file*txt", fileName: "dir/dir/file.txt", expectSuccess: true),
    TestCase(pattern: "**/file*.txt", fileName: "dir/dir/file.txt", expectSuccess: true),
    TestCase(pattern: "**/file*.txt*", fileName: "dir/dir/file.txt", expectSuccess: true),
    TestCase(pattern: "**/**/*.txt", fileName: "dir/dir/file.txt", expectSuccess: true),
    TestCase(pattern: "**/**/*.txt2", fileName: "dir/dir/file.txt", expectSuccess: false),
    TestCase(pattern: "**/*.txt", fileName: "file.txt", expectSuccess: true),
    TestCase(pattern: "**/**/*.txt", fileName: "file.txt", expectSuccess: true),
    TestCase(pattern: "a**/*.txt", fileName: "a/file.txt", expectSuccess: true),
    TestCase(pattern: "a**/*.txt", fileName: "a/dir/file.txt", expectSuccess: true),
    TestCase(pattern: "a**/*.txt", fileName: "a/dir/dir/file.txt", expectSuccess: true),
    TestCase(pattern: "a/*.txt", fileName: "a/dir/file.txt", expectSuccess: false),
    TestCase(pattern: "a/*.txt", fileName: "a/file.txt", expectSuccess: true),
    TestCase(pattern: "a/*.txt**", fileName: "a/file.txt", expectSuccess: true),
    TestCase(pattern: ".*", fileName: ".foo", expectSuccess: true),
    TestCase(pattern: ".*", fileName: "foo", expectSuccess: false),
    TestCase(pattern: "abc.def", fileName: "abcdef", expectSuccess: false),
    TestCase(pattern: "abc.def", fileName: "abc.def", expectSuccess: true),
    TestCase(pattern: "abc.def", fileName: "abcZdef", expectSuccess: false),
    TestCase(pattern: "abc?def", fileName: "abcZdef", expectSuccess: true),
    TestCase(pattern: "abc?def", fileName: "abcdef", expectSuccess: false),
    TestCase(pattern: "**/foo/bar", fileName: "foo/bar", expectSuccess: true),
    TestCase(pattern: "**/foo/bar", fileName: "dir/foo/bar", expectSuccess: true),
    TestCase(pattern: "**/foo/bar", fileName: "dir/dir2/foo/bar", expectSuccess: true),
    TestCase(pattern: "abc/**", fileName: "abc/def", expectSuccess: true),
    TestCase(pattern: "abc/**", fileName: "abc/def/ghi", expectSuccess: true),
    TestCase(pattern: "**/.foo", fileName: ".foo", expectSuccess: true),
    TestCase(pattern: "**/.foo", fileName: "bar.foo", expectSuccess: false),
    TestCase(pattern: "./bar.*", fileName: "bar.foo", expectSuccess: true),
    TestCase(pattern: "./bar.*/", fileName: "bar.foo", expectSuccess: true),
    TestCase(pattern: "a(b)c/def", fileName: "a(b)c/def", expectSuccess: true),
    TestCase(pattern: "a(b)c/def", fileName: "a(b)c/xyz", expectSuccess: false),
    TestCase(pattern: "a.|)$(}+{bc", fileName: "a.|)$(}+{bc", expectSuccess: true),
    TestCase(pattern: "dist/proxy.py-2.4.0rc3.dev36+g08acad9-py3-none-any.whl", fileName: "dist/proxy.py-2.4.0rc3.dev36+g08acad9-py3-none-any.whl", expectSuccess: true),
    TestCase(pattern: "dist/*.whl", fileName: "dist/proxy.py-2.4.0rc3.dev36+g08acad9-py3-none-any.whl", expectSuccess: true),
]

@Suite struct TestGlobber {
    @Test("All glob patterns match", arguments: globTestCases)
    func testGlobMatching(_ test: TestCase) throws {
        let globber = Globber(URL(fileURLWithPath: "/"))
        let found = try globber.glob(test.fileName, test.pattern)
        #expect(found == test.expectSuccess, "expected found to be \(test.expectSuccess), instead got \(found)")
    }

    @Test("Invalid computed regex patterns throw error", arguments: errorGlobTestCases)
    func testInvalidGlob(_ test: TestCase) throws {
        let globber = Globber(URL(fileURLWithPath: "/"))
        #expect(throws: (any Error).self) {
            try globber.glob(test.fileName, test.pattern)
        }
    }

    @Test("All expected patterns match", arguments: testCases)
    func testExpectedPatterns(_ test: TestCase) throws {
        let charactersToTrim = CharacterSet(charactersIn: "/")
        let components = test.fileName
            .trimmingCharacters(in: charactersToTrim)
            .components(separatedBy: "/")

        // tempDir is the directory we're making the files or nested files in
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var fileDir: URL = tempDir

        // testDir is the directory before the last component that we need to create
        components.dropLast().forEach { component in
            var d = fileDir
            if component == ".." {
                d = fileDir.deletingLastPathComponent()
            } else if component != "." {
                d = fileDir.appendingPathComponent(component)
            }
            #expect(throws: Never.self) {
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            }
            fileDir = d
        }

        #expect(throws: Never.self) {
            try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        }
        let testFile = fileDir.appendingPathComponent(components.last!)
        #expect(throws: Never.self) {
            try "".write(to: testFile, atomically: true, encoding: .utf8)
        }

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let globber = Globber(tempDir)
        #expect(throws: Never.self) {
            try globber.match(test.pattern)
            let found: Bool = !globber.results.isEmpty
            let onDisk = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil)?.allObjects ?? []
            #expect(found == test.expectSuccess, "expected match to be \(test.expectSuccess), instead got \(found) \(onDisk)")
        }
    }

    @Test("Test the base directory is not include in results")
    func testBaseDirNotIncluded() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let testDir = tempDir.appendingPathComponent("abc")

        #expect(throws: Never.self) {
            try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        }

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let globber = Globber(testDir)
        #expect(throws: Never.self) {
            try globber.match("abc/**")
            #expect(globber.results.isEmpty, "expected to find no matches, instead found \(globber.results)")
        }
    }

    // MARK: - Directory symlink traversal
    //
    // Globber must be able to descend through a directory symlink whose fully
    // resolved target is still inside the match root (the same containment
    // check BuildFSSync.read()/info() apply before serving content), while
    // continuing to treat a symlink that escapes the root as a leaf with no
    // children. See the discussion on
    // https://github.com/apple/container-ghsa-2v2q-4q35-h585/pull/2.

    @Test("Match descends through an in-context directory symlink")
    func testMatchFollowsInContextDirectorySymlink() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = tempDir.appendingPathComponent("real")
        let link = tempDir.appendingPathComponent("link")
        let file = real.appendingPathComponent("file.txt")

        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let globber = Globber(tempDir)
        try globber.match("link/file.txt")

        // Compare by name rather than exact path: on macOS /var is itself a
        // symlink to /private/var, and FileManager.contentsOfDirectory vs.
        // URL.resolvingSymlinksInPath() normalize that inconsistently, so a
        // temp-dir-rooted URL built by hand won't reliably string-match a URL
        // Globber discovered through the real filesystem APIs.
        #expect(
            globber.results.contains { $0.isSymlink && $0.lastPathComponent == "link" },
            "expected the symlink itself to be preserved in results, got \(globber.results)"
        )
        #expect(
            globber.results.contains { $0.lastPathComponent == "file.txt" },
            "expected the resolved physical file to be present in results, got \(globber.results)"
        )
    }

    @Test("Recursive glob descends through an in-context directory symlink")
    func testMatchRecursiveGlobFollowsInContextDirectorySymlink() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = tempDir.appendingPathComponent("real")
        let link = tempDir.appendingPathComponent("link")
        let file = real.appendingPathComponent("file.txt")

        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let globber = Globber(tempDir)
        try globber.match("link/**")

        #expect(globber.results.contains { $0.isSymlink && $0.lastPathComponent == "link" })
        #expect(globber.results.contains { $0.lastPathComponent == "real" })
        #expect(globber.results.contains { $0.lastPathComponent == "file.txt" })
    }

    @Test("Match does not descend through a directory symlink that escapes the root")
    func testMatchDoesNotDescendThroughSymlinkEscapingRoot() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outsideDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = tempDir.appendingPathComponent("link")
        let secret = outsideDir.appendingPathComponent("secret.txt")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try "supersecret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let globber = Globber(tempDir)
        try globber.match("link/secret.txt")

        #expect(globber.results.isEmpty, "expected no match through a symlink escaping the root, got \(globber.results)")
    }

    @Test("Recursive glob through a symlink escaping the root never leaks out-of-root files")
    func testMatchRecursiveGlobDoesNotLeakOutsideRoot() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outsideDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = tempDir.appendingPathComponent("link")
        let secret = outsideDir.appendingPathComponent("secret.txt")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try "supersecret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let globber = Globber(tempDir)
        try globber.match("link/**")

        let leaked = globber.results.filter { url in
            guard !url.isSymlink else { return false }
            let resolved = url.resolvingSymlinksInPath()
            return !tempDir.parentOf(resolved) && resolved.cleanPath != tempDir.cleanPath
        }
        #expect(leaked.isEmpty, "match() produced non-symlink results that physically resolve outside the root: \(leaked)")
    }
}
