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

import Testing

@Suite
struct TestCLIProgressAuto {
    private let alpine = ContainerFixture.warmupImages[0]

    @Test func testAutoProgressFallsBackToPlainWhenPiped() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["image", "pull", "--progress", "auto", alpine])
            #expect(result.status == 0, "image pull should succeed, stderr: \(result.error)")
            let lines = result.error.components(separatedBy: .newlines)
                .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
            #expect(!lines.isEmpty, "expected plain progress output on stderr when piped")
            #expect(!result.error.contains("\u{1B}["), "expected no ANSI escapes in piped output")
        }
    }

    @Test func testExplicitPlainProgress() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["image", "pull", "--progress", "plain", alpine])
            #expect(
                result.status == 0,
                "image pull --progress plain should succeed, stderr: \(result.error)")
            let lines = result.error.components(separatedBy: .newlines)
                .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
            #expect(!lines.isEmpty, "expected plain progress output on stderr")
            #expect(!result.error.contains("\u{1B}["), "expected no ANSI escapes with --progress plain")
        }
    }

    @Test func testExplicitAnsiProgress() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["image", "pull", "--progress", "ansi", alpine])
            // Verify the command succeeds; ANSI output is suppressed in non-TTY contexts
            // so we don't assert on stderr content here.
            #expect(
                result.status == 0,
                "image pull --progress ansi should succeed, stderr: \(result.error)")
        }
    }

    @Test func testNoneProgressSuppressesOutput() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["image", "pull", "--progress", "none", alpine])
            #expect(
                result.status == 0,
                "image pull --progress none should succeed, stderr: \(result.error)")
            let lines = result.error.components(separatedBy: .newlines)
                .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
            #expect(lines.isEmpty, "expected no progress output on stderr with --progress none")
        }
    }
}
