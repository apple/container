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

class TestCLIExecCommand: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testCreateExecCommand() throws {
        do {
            let name = getTestName()
            try doCreate(name: name)
            defer {
                try? doStop(name: name)
            }
            try doStart(name: name)
            var unameActual = try doExec(name: name, cmd: ["uname"])
            unameActual = unameActual.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(unameActual == "Linux", "expected OS to be Linux, instead got \(unameActual)")
            try doStop(name: name)
        } catch {
            Issue.record("failed to exec in container \(error)")
            return
        }
    }
}
