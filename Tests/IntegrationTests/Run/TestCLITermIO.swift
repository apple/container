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

import ContainerTestSupport
import Foundation
import Testing

/// Tests that an interactive `-it` session with a pty attached does not panic.
@Suite
struct TestCLITermIO {
    @Test func testTermIODoesNotPanic() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(.alpine320)
            let name = "\(f.testID)-c"
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }

            let uniqMessage = UUID().uuidString
            let stdin = Data("echo \(uniqMessage)\nexit\n".utf8)
            let result = try f.run(
                ["run", "--rm", "--name", name, "-it", image, "/bin/sh"],
                stdin: stdin,
                pty: true
            ).check("interactive run should not panic")

            // The container's own pty echoes typed input back on stdout, so skip
            // lines containing "echo" to find the command's actual output.
            let found = result.output.components(separatedBy: .newlines).contains {
                $0.contains(uniqMessage) && !$0.contains("echo")
            }
            #expect(found, "did not find expected stdout line, stdout: \(result.output)")
        }
    }
}
