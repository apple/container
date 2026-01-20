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

import Foundation
import Testing

@testable import ContainerBuild

@Suite class URLExtensionFileSystemTests {

    private var baseTempURL: URL!
    private let fileManager = FileManager.default

    init() throws {
        baseTempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("URLExtensionTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: baseTempURL, withIntermediateDirectories: true, attributes: nil)
    }

    deinit {
        if let baseTempURL = baseTempURL {
            try? fileManager.removeItem(at: baseTempURL)
        }
    }

    // MARK: - Helpers

    private func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    private func createFile(at url: URL, content: String = "") throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil)
        #expect(
            fileManager.createFile(
                atPath: url.path,
                contents: content.data(using: .utf8),
                attributes: nil))
    }

    // MARK: - parentOf Tests

    @Test func testParentOfDirectParent() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir1")
        let childDir = parentDir.appendingPathComponent("dir2")
        try createDirectory(at: childDir)
        #expect(parentDir.parentOf(childDir))
    }

    @Test func testParentOfGrandparent() throws {
        let grandParent = baseTempURL.appendingPathComponent("dir3").appendingPathComponent("test")
        let childDir = grandParent.appendingPathComponent("dir4").appendingPathComponent("dir2")
        try createDirectory(at: childDir)
        #expect(grandParent.parentOf(childDir))
    }

    @Test func testParentOfBaseTemp() throws {
        let childDir = baseTempURL.appendingPathComponent("dir4").appendingPathComponent("dir2")
        try createDirectory(at: childDir)
        #expect(baseTempURL.parentOf(childDir))
    }

    @Test func testParentOfRoot() throws {
        let rootURL = URL(fileURLWithPath: "/")
        let childDir = baseTempURL.appendingPathComponent("dir4")
        try createDirectory(at: childDir)
        #expect(rootURL.parentOf(childDir))
        #expect(rootURL.parentOf(baseTempURL))
    }

    @Test func testParentOfSamePath() throws {
        let dir = baseTempURL.appendingPathComponent("dir4")
        try createDirectory(at: dir)
        let sameDir = URL(fileURLWithPath: dir.path)
        #expect(dir.parentOf(sameDir))
        #expect(sameDir.parentOf(dir))
    }

    @Test func testParentOfRootToRoot() {
        let root1 = URL(fileURLWithPath: "/")
        let root2 = URL(fileURLWithPath: "/")
        #expect(root1.parentOf(root2))
    }

    @Test func testParentOfDifferentPaths() throws {
        let dir1 =
            baseTempURL
            .appendingPathComponent("dir3")
            .appendingPathComponent("test")
            .appendingPathComponent("dir4")
        let dir2 =
            baseTempURL
            .appendingPathComponent("dir3")
            .appendingPathComponent("another")
            .appendingPathComponent("file")
        try createDirectory(at: dir1)
        try createDirectory(at: dir2)
        #expect(false == dir1.parentOf(dir2))
        #expect(false == dir2.parentOf(dir1))
    }

    @Test func testParentOfSiblingPaths() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir3").appendingPathComponent("test")
        let sibling1 = parentDir.appendingPathComponent("dir4")
        let sibling2 = parentDir.appendingPathComponent("dir5")
        try createDirectory(at: sibling1)
        try createDirectory(at: sibling2)
        #expect(false == sibling1.parentOf(sibling2))
        #expect(false == sibling2.parentOf(sibling1))
    }

    @Test func testParentOfChildIsParentFalse() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir4")
        let childDir = parentDir.appendingPathComponent("dir2")
        try createDirectory(at: childDir)
        #expect(false == childDir.parentOf(parentDir))
    }

    @Test func testParentOfPartialNameMatch() throws {
        let partial = baseTempURL.appendingPathComponent("Doc")
        let actualDir = baseTempURL.appendingPathComponent("dir4")
        try createDirectory(at: actualDir)
        #expect(false == partial.parentOf(actualDir))
    }

    @Test func testParentOfPathNormalization() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir4")
        let childDir = parentDir.appendingPathComponent("dir2")
        try createDirectory(at: childDir)
        let normalized =
            baseTempURL
            .appendingPathComponent("dir8")
            .appendingPathComponent("..")
            .appendingPathComponent("dir4")
        #expect(normalized.parentOf(childDir))
    }

    @Test func testParentOfChildWithNormalization() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir4")
        let targetChildDir = parentDir.appendingPathComponent("dir2")
        try createDirectory(at: targetChildDir)
        let normalizedChild =
            parentDir
            .appendingPathComponent("dir9")
            .appendingPathComponent("..")
            .appendingPathComponent("dir2")
        #expect(parentDir.parentOf(normalizedChild))
    }

    @Test func testParentOfPercentEncoding() throws {
        let parentDir = baseTempURL.appendingPathComponent("My dir4")
        let childDir = parentDir.appendingPathComponent("dir2 X")
        try createDirectory(at: childDir)
        let parentEncoded = URL(fileURLWithPath: baseTempURL.path + "/My%20dir4")
        let childEncoded = URL(fileURLWithPath: baseTempURL.path + "/My%20dir4/dir2%20X")
        #expect(parentDir.parentOf(childDir))
        #expect(parentEncoded.parentOf(childEncoded))
        #expect(parentDir.parentOf(childEncoded))
        #expect(parentEncoded.parentOf(childDir))
    }

    @Test func testParentOfNonFileURL() throws {
        let httpURL = URL(string: "http://example.com/path")!
        let fileURL = baseTempURL.appendingPathComponent("file")
        try createFile(at: fileURL)
        #expect(false == httpURL.parentOf(fileURL))
        #expect(false == fileURL.parentOf(httpURL))
    }

    @Test func testRelativeChildPathDirectChild() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir1")
        let childFile = parentDir.appendingPathComponent("dir2").appendingPathComponent("file")
        try createFile(at: childFile)
        let relative = try childFile.relativeChildPath(to: parentDir)
        #expect(relative == "dir2/file")
    }

    @Test func testRelativeChildPathDeeperChild() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir3").appendingPathComponent("test")
        let childFile = parentDir.appendingPathComponent("dir4/dir2/file")
        try createFile(at: childFile)
        let relative = try childFile.relativeChildPath(to: parentDir)
        #expect(relative == "dir4/dir2/file")
    }

    @Test func testRelativeChildPathDirectlyInsideBase() throws {
        let childFile = baseTempURL.appendingPathComponent("file")
        try createFile(at: childFile)
        let relative = try childFile.relativeChildPath(to: baseTempURL)
        #expect(relative == "file")
    }

    @Test func testRelativeChildPathSamePath() throws {
        let dir = baseTempURL.appendingPathComponent("dir4")
        try createDirectory(at: dir)
        let dirCopy = URL(fileURLWithPath: dir.path)
        #expect(try dir.relativeChildPath(to: dirCopy) == "")
        #expect(try dirCopy.relativeChildPath(to: dir) == "")
    }

    @Test func testRelativeChildPathRootChild() throws {
        let rootURL = URL(fileURLWithPath: "/")
        let childDir = baseTempURL.appendingPathComponent("dir4")
        try createDirectory(at: childDir)

        // Compare only the portion that comes after "/"
        let expected =
            baseTempURL
            .standardizedFileURL
            .pathComponents
            .dropFirst()  // remove "/"
            .joined(separator: "/") + "/dir4"

        let relative = try childDir.relativeChildPath(to: rootURL)
        #expect(relative == expected)
    }

    @Test func testRelativeChildPathRootToRootIsEmpty() throws {
        let root1 = URL(fileURLWithPath: "/")
        let root2 = URL(fileURLWithPath: "/")
        #expect(try root1.relativeChildPath(to: root2) == "")
    }

    @Test func testRelativeChildPathNormalization() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir4")
        let childFile = parentDir.appendingPathComponent("dir2/file")
        try createFile(at: childFile)
        let normalizedParent =
            baseTempURL
            .appendingPathComponent("dir8")
            .appendingPathComponent("..")
            .appendingPathComponent("dir4")
        #expect(try childFile.relativeChildPath(to: normalizedParent) == "dir2/file")
    }

    @Test func testRelativeChildPathNormalizedChild() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir4")
        let childFile = parentDir.appendingPathComponent("dir2/file")
        try createFile(at: childFile)
        let normalizedChild =
            parentDir
            .appendingPathComponent("dir9")
            .appendingPathComponent("..")
            .appendingPathComponent("dir2")
            .appendingPathComponent("file")
        #expect(try normalizedChild.relativeChildPath(to: parentDir) == "dir2/file")
    }

    @Test func testRelativeChildPathPercentEncoding() throws {
        let parentDir = baseTempURL.appendingPathComponent("My dir4")
        let childFile = parentDir.appendingPathComponent("dir2 X/file1")
        try createFile(at: childFile)
        #expect(try childFile.relativeChildPath(to: parentDir) == "dir2 X/file1")

        let parentEncoded = URL(fileURLWithPath: baseTempURL.path + "/My%20dir4")
        let childEncoded = URL(fileURLWithPath: baseTempURL.path + "/My%20dir4/dir2%20X/file1")

        #expect(try childEncoded.relativeChildPath(to: parentDir) == "dir2 X/file1")
        #expect(try childEncoded.relativeChildPath(to: parentEncoded) == "dir2 X/file1")
    }

    // MARK: - relativeChildPath Error Tests

    @Test func testRelativeChildPathThrowsWhenNotAChild() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir4")
        let otherDir = baseTempURL.appendingPathComponent("dir7/file")
        try createDirectory(at: parentDir)
        try createDirectory(at: otherDir)

        #expect(throws: (BuildFSSync.Error.pathIsNotChild(otherDir.cleanPath, parentDir.cleanPath)).self) {
            try otherDir.relativeChildPath(to: parentDir)
        }
    }

    @Test func testRelativeChildPathThrowsForSiblings() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir3/test")
        let sibling1 = parentDir.appendingPathComponent("dir4")
        let sibling2 = parentDir.appendingPathComponent("dir5")
        try createDirectory(at: sibling1)
        try createDirectory(at: sibling2)
        #expect(throws: (BuildFSSync.Error.pathIsNotChild(sibling2.cleanPath, sibling1.cleanPath)).self) {
            try sibling2.relativeChildPath(to: sibling1)
        }
    }

    @Test func testRelativeChildPathParentAsChildThrows() throws {
        let parentDir = baseTempURL.appendingPathComponent("dir4")
        let childDir = parentDir.appendingPathComponent("dir2")
        try createDirectory(at: childDir)
        #expect(throws: (BuildFSSync.Error.pathIsNotChild(parentDir.cleanPath, childDir.cleanPath)).self) {
            try parentDir.relativeChildPath(to: childDir)
        }
    }

    // MARK: - cleanPath Tests

    @Test func testCleanPathSimple() throws {
        let file = baseTempURL.appendingPathComponent("file")
        try createFile(at: file)
        #expect(file.cleanPath.hasSuffix("/file"))
        #expect(file.cleanPath.contains(baseTempURL.lastPathComponent))
    }

    @Test func testCleanPathWithSpaces() throws {
        let file = baseTempURL.appendingPathComponent("my file with spaces")
        try createFile(at: file)
        #expect(file.cleanPath.hasSuffix("/my file with spaces"))
        #expect(file.cleanPath.contains(baseTempURL.lastPathComponent))
    }

    @Test func testCleanPathWithPercentEncoding() throws {
        let fileWithSpace = baseTempURL.appendingPathComponent("my file")
        try createFile(at: fileWithSpace)

        let encodedPathString = baseTempURL.path + "/my%20file"
        let urlFromString = URL(fileURLWithPath: encodedPathString)

        #expect(urlFromString.cleanPath == fileWithSpace.cleanPath)
        #expect(urlFromString.cleanPath.hasSuffix("/my file"))
    }
}
