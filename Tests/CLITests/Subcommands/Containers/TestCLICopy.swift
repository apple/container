//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

@testable import ContainerCommands

/// Unit tests for CopyPath parsing utility.
struct CopyPathTests {
    // MARK: - Container Path Parsing

    @Test
    func testParseContainerPathWithAbsolutePath() {
        let result = CopyPath.parse("mycontainer:/app/config.json")
        #expect(result == .container(id: "mycontainer", path: "/app/config.json"))
        #expect(result.isContainer)
        #expect(!result.isLocal)
        #expect(result.containerId == "mycontainer")
        #expect(result.path == "/app/config.json")
    }

    @Test
    func testParseContainerPathWithRelativePath() {
        let result = CopyPath.parse("mycontainer:app/config.json")
        #expect(result == .container(id: "mycontainer", path: "app/config.json"))
    }

    @Test
    func testParseContainerPathWithEmptyPath() {
        let result = CopyPath.parse("mycontainer:")
        #expect(result == .container(id: "mycontainer", path: "/"))
    }

    @Test
    func testParseContainerPathWithUUID() {
        let result = CopyPath.parse("abc123def456:/var/log/app.log")
        #expect(result == .container(id: "abc123def456", path: "/var/log/app.log"))
    }

    // MARK: - Local Path Parsing

    @Test
    func testParseLocalAbsolutePath() {
        let result = CopyPath.parse("/home/user/file.txt")
        #expect(result == .local(path: "/home/user/file.txt"))
        #expect(result.isLocal)
        #expect(!result.isContainer)
        #expect(result.containerId == nil)
    }

    @Test
    func testParseLocalRelativePathWithDot() {
        let result = CopyPath.parse("./config/settings.json")
        #expect(result == .local(path: "./config/settings.json"))
    }

    @Test
    func testParseLocalRelativePathWithDoubleDot() {
        let result = CopyPath.parse("../parent/file.txt")
        #expect(result == .local(path: "../parent/file.txt"))
    }

    @Test
    func testParseLocalPathWithColons() {
        // Paths starting with ./ should be treated as local even with colons
        let result = CopyPath.parse("./file:with:colons.txt")
        #expect(result == .local(path: "./file:with:colons.txt"))
    }

    @Test
    func testParseLocalAbsolutePathWithColons() {
        // Absolute paths should be treated as local even with colons
        let result = CopyPath.parse("/path/to/file:name.txt")
        #expect(result == .local(path: "/path/to/file:name.txt"))
    }

    @Test
    func testParseStdinStdout() {
        let result = CopyPath.parse("-")
        #expect(result == .local(path: "-"))
    }

    @Test
    func testParseSimpleFilename() {
        // A simple filename without path separator should be treated as local
        let result = CopyPath.parse("myfile.txt")
        #expect(result == .local(path: "myfile.txt"))
    }

    // MARK: - Path Properties

    @Test
    func testDirectoryPath() {
        let pathWithSlash = CopyPath.parse("container:/app/")
        #expect(pathWithSlash.isDirectoryPath)

        let pathWithDotSlash = CopyPath.parse("container:/app/.")
        #expect(pathWithDotSlash.isDirectoryPath)

        let regularPath = CopyPath.parse("container:/app/file.txt")
        #expect(!regularPath.isDirectoryPath)
    }

    @Test
    func testCopyContentsOnly() {
        let pathWithDotSlash = CopyPath.parse("container:/app/.")
        #expect(pathWithDotSlash.copyContentsOnly)

        let regularPath = CopyPath.parse("container:/app/")
        #expect(!regularPath.copyContentsOnly)
    }

    @Test
    func testDirname() {
        let path = CopyPath.parse("container:/app/config/settings.json")
        #expect(path.dirname == "/app/config")
    }

    @Test
    func testBasename() {
        let path = CopyPath.parse("container:/app/config/settings.json")
        #expect(path.basename == "settings.json")
    }

    @Test
    func testNormalizedPath() {
        let pathWithDotSlash = CopyPath.parse("container:/app/.")
        #expect(pathWithDotSlash.normalizedPath == "/app")

        let regularPath = CopyPath.parse("container:/app/config")
        #expect(regularPath.normalizedPath == "/app/config")

        let rootDotPath = CopyPath.parse("container:/.")
        #expect(rootDotPath.normalizedPath == "/")
    }

    // MARK: - Edge Cases

    @Test
    func testEmptyString() {
        // Empty string should be treated as local empty path
        let result = CopyPath.parse("")
        #expect(result == .local(path: ""))
    }

    @Test
    func testContainerIdWithNumbers() {
        let result = CopyPath.parse("container123:/path")
        #expect(result == .container(id: "container123", path: "/path"))
    }

    @Test
    func testContainerIdWithHyphens() {
        let result = CopyPath.parse("my-container:/path")
        #expect(result == .container(id: "my-container", path: "/path"))
    }

    @Test
    func testContainerIdWithUnderscores() {
        let result = CopyPath.parse("my_container:/path")
        #expect(result == .container(id: "my_container", path: "/path"))
    }

    // MARK: - Additional Edge Cases

    @Test
    func testTildePathWithSlash() {
        // ~/file is correctly treated as local (no colon in path)
        let result = CopyPath.parse("~/Documents/file.txt")
        #expect(result == .local(path: "~/Documents/file.txt"))
    }

    @Test
    func testTildeOnly() {
        // Just ~ should be treated as local
        let result = CopyPath.parse("~")
        #expect(result == .local(path: "~"))
    }

    @Test
    func testTildeWithColon() {
        // ~:path would be parsed as container "~" with path
        // This is technically correct parsing - ~ is a valid container name
        let result = CopyPath.parse("~:/path")
        #expect(result == .container(id: "~", path: "/path"))
    }

    @Test
    func testHiddenFileWithoutSlash() {
        // .hidden (without ./) should be treated as local
        // BUG: Currently would be parsed as container ".hidden" with path "/"
        let result = CopyPath.parse(".hiddenfile")
        // This test documents the current behavior
        #expect(result == .local(path: ".hiddenfile"))
    }

    @Test
    func testJustColon() {
        // Just ":" should be treated as local (empty container id is invalid)
        let result = CopyPath.parse(":")
        #expect(result == .local(path: ":"))
    }

    @Test
    func testContainerRootPath() {
        // container:/ should work
        let result = CopyPath.parse("mycontainer:/")
        #expect(result == .container(id: "mycontainer", path: "/"))
    }

    @Test
    func testPathWithSpaces() {
        // Paths with spaces should be preserved
        let result = CopyPath.parse("container:/path/with spaces/file.txt")
        #expect(result == .container(id: "container", path: "/path/with spaces/file.txt"))
    }

    @Test
    func testLocalPathWithSpaces() {
        let result = CopyPath.parse("/path/with spaces/file.txt")
        #expect(result == .local(path: "/path/with spaces/file.txt"))
    }

    @Test
    func testMultipleColonsInPath() {
        // container:path:with:colons should parse correctly
        let result = CopyPath.parse("container:/path:with:colons.txt")
        #expect(result == .container(id: "container", path: "/path:with:colons.txt"))
    }

    @Test
    func testWhitespaceOnlyPath() {
        let result = CopyPath.parse("   ")
        #expect(result == .local(path: "   "))
    }

    @Test
    func testContainerPathWithDotDot() {
        // container:../path should be parsed (though semantically questionable)
        let result = CopyPath.parse("container:../path")
        #expect(result == .container(id: "container", path: "../path"))
    }

    @Test
    func testContainerIdWithDots() {
        let result = CopyPath.parse("my.container.name:/path")
        #expect(result == .container(id: "my.container.name", path: "/path"))
    }

    @Test
    func testVeryLongContainerId() {
        let longId = String(repeating: "a", count: 100)
        let result = CopyPath.parse("\(longId):/path")
        #expect(result == .container(id: longId, path: "/path"))
    }

    @Test
    func testVeryLongPath() {
        let longPath = "/" + String(repeating: "a/", count: 100)
        let result = CopyPath.parse("container:\(longPath)")
        #expect(result == .container(id: "container", path: longPath))
    }

    @Test
    func testPathWithNewline() {
        // Paths with newlines - edge case
        let result = CopyPath.parse("container:/path/with\nnewline")
        #expect(result == .container(id: "container", path: "/path/with\nnewline"))
    }

    @Test
    func testPathWithTab() {
        let result = CopyPath.parse("container:/path/with\ttab")
        #expect(result == .container(id: "container", path: "/path/with\ttab"))
    }

    @Test
    func testUnicodeInPath() {
        let result = CopyPath.parse("container:/路径/文件.txt")
        #expect(result == .container(id: "container", path: "/路径/文件.txt"))
    }

    @Test
    func testEmojiInPath() {
        let result = CopyPath.parse("container:/📁/file.txt")
        #expect(result == .container(id: "container", path: "/📁/file.txt"))
    }

    @Test
    func testBackslashInPath() {
        // Backslashes should be preserved (not treated as escape)
        let result = CopyPath.parse("container:/path\\with\\backslash")
        #expect(result == .container(id: "container", path: "/path\\with\\backslash"))
    }

    @Test
    func testDotDotSlashPrefix() {
        // ../path should always be local
        let result = CopyPath.parse("../container:fake")
        #expect(result == .local(path: "../container:fake"))
    }

    @Test
    func testDotSlashWithColon() {
        // ./container:path should be local
        let result = CopyPath.parse("./container:path")
        #expect(result == .local(path: "./container:path"))
    }

    @Test
    func testSingleDot() {
        // Just "." should be local
        let result = CopyPath.parse(".")
        #expect(result == .local(path: "."))
    }

    @Test
    func testDoubleDot() {
        // Just ".." should be local
        let result = CopyPath.parse("..")
        #expect(result == .local(path: ".."))
    }

    @Test
    func testContainerIdStartingWithNumber() {
        let result = CopyPath.parse("123container:/path")
        #expect(result == .container(id: "123container", path: "/path"))
    }

    @Test
    func testFullUUIDContainerId() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let result = CopyPath.parse("\(uuid):/path")
        #expect(result == .container(id: uuid, path: "/path"))
    }
}
