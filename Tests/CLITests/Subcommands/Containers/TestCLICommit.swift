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

@Suite(.serialSuites)
class TestCLICommitCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testCommitCommand() throws {
        let name = getTestName()
        let imageRef = "localhost/committed-\(name):latest"
        let committedContainerName = "\(name)-committed"
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
            try? doStop(name: committedContainerName)
            try? doRemove(name: committedContainerName)
            try? doRemoveImages(images: [imageRef])
        }

        let mustBeInImage = "must-be-in-committed-image"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /committed-file"])

        try doStop(name: name)

        let output = try doCommit(name: name, reference: imageRef)
        #expect(output == imageRef, "commit should print the image reference")

        let present = try isImagePresent(targetImage: imageRef)
        #expect(present, "committed image should be present in image list")

        try doLongRun(name: committedContainerName, image: imageRef, autoRemove: false)
        let committedOutput = try doExec(name: committedContainerName, cmd: ["cat", "/committed-file"])
        #expect(committedOutput.trimmingCharacters(in: .whitespacesAndNewlines) == mustBeInImage)
    }

    @Test func testCommitLiveCommand() throws {
        let name = getTestName()
        let imageRef = "localhost/committed-live-\(name):latest"
        let committedContainerName = "\(name)-committed-live"
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doStop(name: name)
            try? doRemove(name: name)
            try? doStop(name: committedContainerName)
            try? doRemove(name: committedContainerName)
            try? doRemoveImages(images: [imageRef])
        }

        let mustBeInImage = "must-be-in-committed-live-image"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /committed-live-file"])

        let output = try doCommit(name: name, reference: imageRef, live: true)
        #expect(output == imageRef, "commit --live should print the image reference")

        let present = try isImagePresent(targetImage: imageRef)
        #expect(present, "committed live image should be present in image list")

        try doLongRun(name: committedContainerName, image: imageRef, autoRemove: false)
        let committedOutput = try doExec(name: committedContainerName, cmd: ["cat", "/committed-live-file"])
        #expect(committedOutput.trimmingCharacters(in: .whitespacesAndNewlines) == mustBeInImage)
    }
}
