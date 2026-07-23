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
import Testing

@Suite
struct TestCLIHelp {
    @Test func testRootHelp() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["--help"])
            #expect(result.status == 0, "root help should succeed, stderr: \(result.error)")
            #expect(
                result.output.contains("OVERVIEW: A container platform for macOS"),
                "output should contain overview section"
            )
        }
    }

    @Test func testHelp() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["help"])
            #expect(result.status == 0, "help should succeed, stderr: \(result.error)")
            #expect(
                result.output.contains("OVERVIEW: A container platform for macOS"),
                "output should contain overview section"
            )
        }
    }

    @Test func testDefaultHelp() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run([])
            #expect(result.status == 0, "default help should succeed, stderr: \(result.error)")
            #expect(
                result.output.contains("OVERVIEW: A container platform for macOS"),
                "output should contain overview section"
            )
        }
    }

    @Test func testDebugHelp() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["--debug", "help"])
            #expect(result.status == 0, "help should succeed, stderr: \(result.error)")
            #expect(
                result.output.contains("OVERVIEW: A container platform for macOS"),
                "output should contain overview section"
            )
        }
    }
}
