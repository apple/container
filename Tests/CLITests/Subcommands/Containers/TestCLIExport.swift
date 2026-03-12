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
import Foundation
import Testing

class TestCLIExportCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testExportCommand() throws {
        let name = getTestName()
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
        }

        let mustBeInImage = "must-be-in-image"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo"])

        _ = try doExec(name: name, cmd: ["sh", "-c", "mkdir -p /parent/child"])
        let hardlinkMustRemain = "hardlink-must-remain"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(hardlinkMustRemain) > /parent/child/bar"])
        _ = try doExec(name: name, cmd: ["sh", "-c", "ln /parent/child/bar /bar"])

        let symlinkMustRemain = "symlink-must-remain"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(symlinkMustRemain) > /parent/child/baz"])
        _ = try doExec(name: name, cmd: ["sh", "-c", "ln /parent/child/baz /baz"])

        try doStop(name: name)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString)

        try doExport(name: name, filepath: tempFile.path())

        let attrs = try FileManager.default.attributesOfItem(atPath: tempFile.path())
        let fileSize = attrs[.size] as! UInt64
        #expect(fileSize > 0)

        // TODO: verify foo bar baz are in tar file.
        let reader = try ArchiveReader(file: tempFile)
        let (foo, fooData) = try reader.extractFile(path: "/foo")
        #expect(foo.fileType == .regular)
        #expect(String(data: fooData, encoding: .utf8)?.starts(with: mustBeInImage) ?? false)
    }
}
