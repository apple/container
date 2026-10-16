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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerCommands

struct ContainerExportTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("test-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    @Test
    func replaceItemWritesTheArchiveToANewPath() throws {
        try withTemporaryDirectory { directory in
            let archive = directory.appendingPathComponent("archive.tar")
            let output = directory.appendingPathComponent("out.tar")
            try Data("new".utf8).write(to: archive)

            try Application.ContainerExport.replaceItem(at: output.path, with: archive)

            #expect(try String(contentsOf: output, encoding: .utf8) == "new")
            #expect(!FileManager.default.fileExists(atPath: archive.path))
        }
    }

    @Test
    func replaceItemReplacesAnExistingFile() throws {
        try withTemporaryDirectory { directory in
            let archive = directory.appendingPathComponent("archive.tar")
            let output = directory.appendingPathComponent("out.tar")
            try Data("new".utf8).write(to: archive)
            try Data("old".utf8).write(to: output)

            try Application.ContainerExport.replaceItem(at: output.path, with: archive)

            #expect(try String(contentsOf: output, encoding: .utf8) == "new")
        }
    }

    @Test
    func replaceItemLeavesADirectoryAndItsContentsAlone() throws {
        try withTemporaryDirectory { directory in
            let archive = directory.appendingPathComponent("archive.tar")
            let output = directory.appendingPathComponent("out")
            try Data("new".utf8).write(to: archive)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: output.appendingPathComponent("notes.txt"))

            #expect {
                try Application.ContainerExport.replaceItem(at: output.path, with: archive)
            } throws: { error in
                (error as? ContainerizationError)?.message.contains("is a directory") == true
            }

            #expect(try String(contentsOf: output.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep")
            #expect(FileManager.default.fileExists(atPath: archive.path))
        }
    }

    @Test
    func replaceItemKeepsTheOldFileWhenTheArchiveIsMissing() throws {
        try withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("out.tar")
            try Data("old".utf8).write(to: output)

            #expect(throws: (any Error).self) {
                try Application.ContainerExport.replaceItem(at: output.path, with: directory.appendingPathComponent("missing.tar"))
            }

            #expect(try String(contentsOf: output, encoding: .utf8) == "old")
        }
    }
}
