//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

/// Tests for HOME environment variable handling in containers (Issue #108)
class TestCLIHomeEnvironment: CLITest {

    @Test func TestDefaultHomeEnvironment() throws {
        let (output, _, status) = try run(arguments: ["run", "--rm", "--user", "root", alpine, "sh", "-c", "pwd; cd; pwd"])

        guard status == 0 else {
            Issue.record("Container test failed with status \(status)")
            return
        }
        guard !output.isEmpty else { return }

        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)

        #expect(lines[0] == "/", "pwd (initial) should show current directory")
        #expect(lines[1] == "/root", "pwd (after cd) should show /root")
    }

    @Test func TestCustomHomeEnvironment() throws {
        let (output, _, status) = try run(arguments: ["run", "--rm", "--env", "HOME=/tmp", alpine, "sh", "-c", "pwd; cd; pwd"])

        guard status == 0 else {
            Issue.record("Container test failed with status \(status)")
            return
        }
        guard !output.isEmpty else { return }

        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)

        #expect(lines[0] == "/", "pwd (initial) should show current directory")
        #expect(lines[1] == "/tmp", "pwd (after cd) should show /tmp")
    }
}
