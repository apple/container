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

extension TestCLIBuildBase {
    class CLIBuilderTarExportTest: TestCLIBuildBase {
        override init() throws {
            try super.init()
        }

        deinit {
            try? builderDelete(force: true)
        }

        @Test func testBuildExportTar() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch
                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [
                .file("emptyFile", content: .zeroFilled(size: 1))
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let exportPath = tempDir.appendingPathComponent("export.tar")
            let response = try run(arguments: [
                "build",
                "-f", tempDir.appendingPathComponent("Dockerfile").path,
                "-o", "type=tar,dest=\(exportPath.path)",
                tempDir.appendingPathComponent("context").path,
            ])

            #expect(response.status == 0, "build with tar export should succeed")
            #expect(FileManager.default.fileExists(atPath: exportPath.path), "tar file should exist at \(exportPath.path)")
            #expect(response.output.contains("Successfully exported to \(exportPath.path)"), "should show export success message")

            let attributes = try FileManager.default.attributesOfItem(atPath: exportPath.path)
            let fileSize = attributes[.size] as? Int ?? 0
            #expect(fileSize > 0, "exported tar file should not be empty")
        }

        @Test func testBuildExportTarToDirectory() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                RUN echo "test content" > /test.txt
                """
            try createContext(tempDir: tempDir, dockerfile: dockerfile)

            let exportDir = tempDir.appendingPathComponent("exports")
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

            let response = try run(arguments: [
                "build",
                "-f", tempDir.appendingPathComponent("Dockerfile").path,
                "-o", "type=tar,dest=\(exportDir.path)",
                tempDir.appendingPathComponent("context").path,
            ])

            #expect(response.status == 0, "build with tar export to directory should succeed")

            let expectedTar = exportDir.appendingPathComponent("out.tar")
            #expect(FileManager.default.fileExists(atPath: expectedTar.path), "tar file should exist at \(expectedTar.path)")
            #expect(response.output.contains("Successfully exported to \(expectedTar.path)"), "should show export success message")
        }

        @Test func testBuildExportTarMultipleRuns() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch
                ADD testFile /
                """
            let context: [FileSystemEntry] = [
                .file("testFile", content: .data("test data".data(using: .utf8)!))
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let exportDir = tempDir.appendingPathComponent("exports")
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

            // First build
            var response = try run(arguments: [
                "build",
                "-f", tempDir.appendingPathComponent("Dockerfile").path,
                "-o", "type=tar,dest=\(exportDir.path)",
                tempDir.appendingPathComponent("context").path,
            ])
            #expect(response.status == 0, "first build should succeed")

            let firstTar = exportDir.appendingPathComponent("out.tar")
            #expect(FileManager.default.fileExists(atPath: firstTar.path), "first tar should exist")

            // Second build - should create out.tar.1
            response = try run(arguments: [
                "build",
                "-f", tempDir.appendingPathComponent("Dockerfile").path,
                "-o", "type=tar,dest=\(exportDir.path)",
                tempDir.appendingPathComponent("context").path,
            ])
            #expect(response.status == 0, "second build should succeed")

            let secondTar = exportDir.appendingPathComponent("out.tar.1")
            #expect(FileManager.default.fileExists(atPath: secondTar.path), "second tar should exist at out.tar.1")
        }

        @Test func testBuildExportTarInvalidDest() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch
                """
            try createContext(tempDir: tempDir, dockerfile: dockerfile)

            let response = try run(arguments: [
                "build",
                "-f", tempDir.appendingPathComponent("Dockerfile").path,
                "-o", "type=tar",  // Missing dest parameter
                tempDir.appendingPathComponent("context").path,
            ])

            #expect(response.status != 0, "build without dest should fail")
            #expect(response.error.contains("dest field is required"), "error should mention missing dest")
        }
    }
}
