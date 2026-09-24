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

struct ContainerLogsTailTests {
    private func withTempLog(_ contents: String, _ body: (FileHandle) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-logs-tail-\(UUID().uuidString).log")
        try Data(contents.utf8).write(to: url)
        let fh = try FileHandle(forReadingFrom: url)
        defer {
            try? fh.close()
            try? FileManager.default.removeItem(at: url)
        }
        try body(fh)
    }

    @Test("returns the last n complete lines for short input")
    func lastNShortLines() throws {
        let contents = (1...10).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try withTempLog(contents) { fh in
            let lines = try Application.ContainerLogs.lastLines(fh: fh, n: 3)
            #expect(lines == ["line-8", "line-9", "line-10"])
        }
    }

    @Test("n larger than the line count returns every line")
    func nLargerThanLineCount() throws {
        try withTempLog("a\nb\n") { fh in
            let lines = try Application.ContainerLogs.lastLines(fh: fh, n: 10)
            #expect(lines == ["a", "b"])
        }
    }

    @Test("a single line longer than the 1024-byte chunk is not truncated")
    func longSingleLineNotTruncated() throws {
        // Regression: a log line larger than the 1024-byte backward-read chunk
        // was returned with its beginning cut off by `container logs -n 1`.
        let long = "START" + String(repeating: "X", count: 3000) + "END"
        try withTempLog(long + "\n") { fh in
            let lines = try Application.ContainerLogs.lastLines(fh: fh, n: 1)
            #expect(lines == [long])
        }
    }

    @Test("multiple lines spanning several chunks keep the oldest line intact")
    func longLinesSpanningChunks() throws {
        // Each line is 800 bytes; the last two together exceed one 1024-byte
        // chunk, which previously truncated the older of the two.
        let a = String(repeating: "A", count: 800)
        let b = String(repeating: "B", count: 800)
        let c = String(repeating: "C", count: 800)
        try withTempLog([a, b, c].joined(separator: "\n") + "\n") { fh in
            let lines = try Application.ContainerLogs.lastLines(fh: fh, n: 2)
            #expect(lines == [b, c])
        }
    }
}
