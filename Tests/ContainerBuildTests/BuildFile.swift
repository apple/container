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
import Logging
import Testing

@testable import ContainerBuild

@Suite class BuildFileResolvePathTests {
    private var baseTempURL: URL
    private let fileManager = FileManager.default

    init() throws {
        self.baseTempURL = URL.temporaryDirectory
            .appendingPathComponent("BuildFileTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: baseTempURL, withIntermediateDirectories: true, attributes: nil)
    }

    deinit {
        try? fileManager.removeItem(at: baseTempURL)
    }

    private func createFile(at url: URL, content: String = "") throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let created = fileManager.createFile(
            atPath: url.path,
            contents: content.data(using: .utf8),
            attributes: nil
        )
        try #require(created)
    }

    @Test func testResolvePathFindsDockerfile() throws {
        let contextDir = baseTempURL.path
        let dockerfilePath = baseTempURL.appendingPathComponent("Dockerfile")
        try createFile(at: dockerfilePath, content: "FROM alpine")

        let result = try BuildFile.resolvePath(contextDir: contextDir)

        #expect(result == dockerfilePath.path)
    }

    @Test func testResolvePathFindsContainerfile() throws {
        let contextDir = baseTempURL.path
        let containerfilePath = baseTempURL.appendingPathComponent("Containerfile")
        try createFile(at: containerfilePath, content: "FROM alpine")

        let result = try BuildFile.resolvePath(contextDir: contextDir)

        #expect(result == containerfilePath.path)
    }

    @Test func testResolvePathPrefersDockerfileWhenBothExist() throws {
        let contextDir = baseTempURL.path
        let dockerfilePath = baseTempURL.appendingPathComponent("Dockerfile")
        let containerfilePath = baseTempURL.appendingPathComponent("Containerfile")
        try createFile(at: dockerfilePath, content: "FROM alpine")
        try createFile(at: containerfilePath, content: "FROM ubuntu")

        let result = try BuildFile.resolvePath(contextDir: contextDir)

        #expect(result == dockerfilePath.path)
    }

    @Test func testResolvePathReturnsNilWhenNoFilesExist() throws {
        let contextDir = baseTempURL.path

        let result = try BuildFile.resolvePath(contextDir: contextDir)

        #expect(result == nil)
    }

    @Test func testResolvePathWithEmptyDirectory() throws {
        let emptyDir = baseTempURL.appendingPathComponent("empty")
        try fileManager.createDirectory(at: emptyDir, withIntermediateDirectories: true, attributes: nil)

        let result = try BuildFile.resolvePath(contextDir: emptyDir.path)

        #expect(result == nil)
    }

    @Test func testResolvePathWithNestedContextDirectory() throws {
        let nestedDir = baseTempURL.appendingPathComponent("project/build")
        try fileManager.createDirectory(at: nestedDir, withIntermediateDirectories: true, attributes: nil)
        let dockerfilePath = nestedDir.appendingPathComponent("Dockerfile")
        try createFile(at: dockerfilePath, content: "FROM node")

        let result = try BuildFile.resolvePath(contextDir: nestedDir.path)

        #expect(result == dockerfilePath.path)
    }

    @Test func testResolvePathWithRelativeContextDirectory() throws {
        let nestedDir = baseTempURL.appendingPathComponent("project")
        try fileManager.createDirectory(at: nestedDir, withIntermediateDirectories: true, attributes: nil)
        let dockerfilePath = nestedDir.appendingPathComponent("Dockerfile")
        try createFile(at: dockerfilePath, content: "FROM python")

        // Test with the absolute path
        let result = try BuildFile.resolvePath(contextDir: nestedDir.path)

        #expect(result == dockerfilePath.path)
    }
}
