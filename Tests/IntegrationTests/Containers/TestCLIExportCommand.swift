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

@Suite
struct TestCLIExportCommand {
    @Test func testExportCommand() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
            try await f.withContainer(image: image, autoRemove: false) { name in
                let mustBeInImage = "must-be-in-image"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo"])
                try f.doExec(name, cmd: ["sh", "-c", "mkdir -p /parent/child"])
                let hardlinkMustRemain = "hardlink-must-remain"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(hardlinkMustRemain) > /parent/child/bar"])
                try f.doExec(name, cmd: ["sh", "-c", "ln /parent/child/bar /bar"])
                let symlinkMustRemain = "symlink-must-remain"
                try f.doExec(name, cmd: ["sh", "-c", "echo \(symlinkMustRemain) > /parent/child/baz"])
                try f.doExec(name, cmd: ["sh", "-c", "ln /parent/child/baz /baz"])

                try f.doStop(name)

                let exportPath = f.testDir.appending("export.tar")
                try f.doExport(name, to: exportPath)

                let exportURL = URL(filePath: exportPath.string)
                let attrs = try FileManager.default.attributesOfItem(atPath: exportPath.string)
                let fileSize = attrs[.size] as! UInt64
                #expect(fileSize > 0)

                // TODO: verify foo bar baz are in tar file.
                let reader = try ArchiveReader(file: exportURL)
                let (foo, fooData) = try reader.extractFile(path: "/foo")
                #expect(foo.fileType == .regular)
                #expect(String(data: fooData, encoding: .utf8)?.starts(with: mustBeInImage) ?? false)
            }
        }
    }
}
