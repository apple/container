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

import Testing

class TestCLIRunLifecycle: CLITest {
    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func testRunFailureCleanup() throws {
        let name = getTestName()

        // try to create a container we know will fail
        let badArgs: [String] = [
            "--rm",
            "--user",
            name,
        ]
        #expect(throws: CLIError.self, "expect container to fail with invalid user") {
            try self.doLongRun(name: name, args: badArgs)
        }

        // try to create a container with the same name but no user that should succeed
        #expect(throws: Never.self, "expected container run to succeed") {
            try self.doLongRun(name: name, args: [])
            defer {
                try? self.doStop(name: name)
            }
            let _ = try self.doExec(name: name, cmd: ["date"])
            try self.doStop(name: name)
        }
    }
}
