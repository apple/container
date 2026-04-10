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

class TestCLIProgressAuto: CLITest {
    @Test func testAutoProgressFallsBackToPlainWhenPiped() throws {
        let (_, _, error, status) = try run(arguments: [
            "image", "pull",
            "--progress", "auto",
            alpine,
        ])
        #expect(status == 0, "image pull should succeed, stderr: \(error)")
        let lines = error.components(separatedBy: .newlines)
            .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
        #expect(!lines.isEmpty, "expected plain progress output on stderr when piped")
        #expect(!error.contains("\u{1B}["), "expected no ANSI escapes in piped output")
    }

    @Test func testExplicitPlainProgress() throws {
        let (_, _, error, status) = try run(arguments: [
            "image", "pull",
            "--progress", "plain",
            alpine,
        ])
        #expect(status == 0, "image pull --progress plain should succeed, stderr: \(error)")
        let lines = error.components(separatedBy: .newlines)
            .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
        #expect(!lines.isEmpty, "expected plain progress output on stderr")
        #expect(!error.contains("\u{1B}["), "expected no ANSI escapes with --progress plain")
    }

    @Test func testExplicitAnsiProgress() throws {
        let (_, _, error, status) = try run(arguments: [
            "image", "pull",
            "--progress", "ansi",
            alpine,
        ])
        #expect(status == 0, "image pull --progress ansi should succeed, stderr: \(error)")
        let lines = error.components(separatedBy: .newlines)
            .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
        #expect(!lines.isEmpty, "expected ansi progress output on stderr")
    }

    @Test func testNoneProgressSuppressesOutput() throws {
        let (_, _, error, status) = try run(arguments: [
            "image", "pull",
            "--progress", "none",
            alpine,
        ])
        #expect(status == 0, "image pull --progress none should succeed, stderr: \(error)")
        let lines = error.components(separatedBy: .newlines)
            .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
        #expect(lines.isEmpty, "expected no progress output on stderr with --progress none")
    }
}
