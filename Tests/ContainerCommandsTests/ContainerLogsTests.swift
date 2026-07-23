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

@testable import ContainerCommands

struct ContainerLogsTests {
    /// Writes `contents` to a temp file and runs `lastLines` against it.
    private func lastLines(of contents: String, n: Int) throws -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return try Application.ContainerLogs.lastLines(fh: fh, n: n)
    }

    @Test("returns the complete oldest line when it exceeds the 1024-byte chunk")
    func singleLongLineIsNotTruncated() throws {
        let line = "START" + String(repeating: "X", count: 3000) + "END"
        let result = try lastLines(of: line + "\n", n: 1)
        #expect(result == [line])
    }

    @Test("does not truncate the oldest of N lines that span multiple chunks")
    func multipleLinesSpanningChunksAreNotTruncated() throws {
        let l1 = String(repeating: "A", count: 800)
        let l2 = String(repeating: "B", count: 800)
        let l3 = String(repeating: "C", count: 800)
        let result = try lastLines(of: "\(l1)\n\(l2)\n\(l3)\n", n: 2)
        #expect(result == [l2, l3])
    }

    @Test("returns the last N short lines")
    func lastNShortLines() throws {
        let result = try lastLines(of: "line1\nline2\nline3\nline4\nline5\n", n: 3)
        #expect(result == ["line3", "line4", "line5"])
    }

    @Test("returns all lines when N exceeds the line count")
    func nLargerThanFile() throws {
        let result = try lastLines(of: "a\nb\nc\n", n: 10)
        #expect(result == ["a", "b", "c"])
    }
}
