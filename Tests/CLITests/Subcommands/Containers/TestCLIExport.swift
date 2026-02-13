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

class TestCLIExportCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testExportCommand() throws {
        let name = getTestName()
        try doLongRun(name: name, autoRemove: false)
        defer {
            try? doRemove(name: name)
        }

        let mustBeInImage = "must-be-in-image"
        _ = try doExec(name: name, cmd: ["sh", "-c", "echo \(mustBeInImage) > /foo"])

        try doStop(name: name)
        try doExport(name: name, image: name)
        defer {
            try? doRemoveImages(images: [name])
        }

        let exported = "\(name)-from-exported"
        try doLongRun(name: exported, image: name)
        defer {
            try? doStop(name: exported)
        }

        let foo = try doExec(name: exported, cmd: ["cat", "/foo"])
        #expect(foo == mustBeInImage + "\n")
    }
}
