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

import Darwin
import Foundation
import SystemPackage
import Testing

@testable import ContainerCommands

struct ImageLoadTests {
    @Test
    func regularInputDoesNotNeedStaging() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let input = tempDir.appendingPathComponent("image.tar")
        try Data("archive".utf8).write(to: input)

        #expect(try Application.ImageLoad.shouldStageInput(FilePath(input.path)) == false)
    }

    @Test
    func nonRegularInputNeedsStaging() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let input = tempDir.appendingPathComponent("image.tar")
        try #require(mkfifo(input.path, 0o600) == 0)

        #expect(try Application.ImageLoad.shouldStageInput(FilePath(input.path)))
    }

    @Test
    func fileDescriptorInputNeedsStaging() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let input = tempDir.appendingPathComponent("image.tar")
        try Data("archive".utf8).write(to: input)

        let inputHandle = try FileHandle(forReadingFrom: input)
        defer {
            try? inputHandle.close()
        }

        let descriptorPath = "/dev/fd/\(inputHandle.fileDescriptor)"

        #expect(try Application.ImageLoad.shouldStageInput(FilePath(descriptorPath)))
    }

    @Test
    func copyArchivePreservesBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let input = tempDir.appendingPathComponent("input.tar")
        let output = tempDir.appendingPathComponent("output.tar")
        let payload = Data((0..<8192).map { UInt8($0 % 251) })
        try payload.write(to: input)

        let inputHandle = try FileHandle(forReadingFrom: input)
        defer {
            try? inputHandle.close()
        }

        try Application.ImageLoad.copyArchive(from: inputHandle, to: output)

        #expect(try Data(contentsOf: output) == payload)
    }
}
