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

@Suite(.serialized)
struct TestCLIBuilderTarExportSerial {
    @Test func testBuildExportTar() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD emptyFile /",
                    context: [.file("emptyFile", content: .zeroFilled(size: 1))])

                let exportPath = dir.appending("export.tar")
                let result = try f.run([
                    "build",
                    "-f", dir.appending("Dockerfile").string,
                    "-o", "type=tar,dest=\(exportPath.string)",
                    dir.appending("context").string,
                ])
                #expect(result.status == 0, "build with tar export should succeed")
                #expect(FileManager.default.fileExists(atPath: exportPath.string), "tar file should exist")
                #expect(result.output.contains(exportPath.string), "output should reference export path")
                let attrs = try FileManager.default.attributesOfItem(atPath: exportPath.string)
                #expect((attrs[.size] as? Int ?? 0) > 0, "exported tar should not be empty")
            }
        }
    }

    @Test func testBuildExportTarToDirectory() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nRUN echo \"test\" > /test.txt")

                let exportDir = dir.appending("exports")
                try FileManager.default.createDirectory(
                    atPath: exportDir.string, withIntermediateDirectories: true, attributes: nil)

                let result = try f.run([
                    "build",
                    "-f", dir.appending("Dockerfile").string,
                    "-o", "type=tar,dest=\(exportDir.string)",
                    dir.appending("context").string,
                ])
                #expect(result.status == 0, "build with tar export to directory should succeed")
                let expectedTar = exportDir.appending("out.tar")
                #expect(
                    FileManager.default.fileExists(atPath: expectedTar.string),
                    "tar file should exist at out.tar")
                #expect(result.output.contains(expectedTar.string), "output should reference out.tar")
            }
        }
    }

    @Test func testBuildExportTarMultipleRuns() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD testFile /",
                    context: [.file("testFile", content: .data("test data".data(using: .utf8)!))])

                let exportDir = dir.appending("exports")
                try FileManager.default.createDirectory(
                    atPath: exportDir.string, withIntermediateDirectories: true, attributes: nil)

                let buildArgs = [
                    "build",
                    "-f", dir.appending("Dockerfile").string,
                    "-o", "type=tar,dest=\(exportDir.string)",
                    dir.appending("context").string,
                ]

                let r1 = try f.run(buildArgs)
                #expect(r1.status == 0, "first build should succeed")
                #expect(FileManager.default.fileExists(atPath: exportDir.appending("out.tar").string))

                let r2 = try f.run(buildArgs)
                #expect(r2.status == 0, "second build should succeed")
                #expect(
                    FileManager.default.fileExists(atPath: exportDir.appending("out.tar.1").string),
                    "second tar should exist at out.tar.1")
            }
        }
    }

    @Test func testBuildExportTarInvalidDest() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(dir: dir, dockerfile: "FROM scratch")

                let result = try f.run([
                    "build",
                    "-f", dir.appending("Dockerfile").string,
                    "-o", "type=tar",  // missing dest
                    dir.appending("context").string,
                ])
                #expect(result.status != 0, "build without dest should fail")
                #expect(result.error.contains("dest field is required"))
            }
        }
    }
}
