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

struct LogTailerTests {
    /// Write `contents` to a temporary file and read its last `n` lines back.
    private func lastLines(of contents: String, n: Int) throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return try LogTailer.lastLines(fh: fh, n: n)
    }

    @Test
    func returnsTrailingLines() throws {
        let lines = try lastLines(of: "one\ntwo\nthree\n", n: 2)
        #expect(lines == ["two", "three"])
    }

    @Test
    func returnsEveryLineWhenFileIsShorterThanRequested() throws {
        let lines = try lastLines(of: "one\ntwo\n", n: 10)
        #expect(lines == ["one", "two"])
    }

    @Test
    func handlesFinalLineWithoutTrailingNewline() throws {
        let lines = try lastLines(of: "one\ntwo", n: 1)
        #expect(lines == ["two"])
    }

    @Test
    func skipsBlankLines() throws {
        let lines = try lastLines(of: "one\n\n\ntwo\n\n", n: 2)
        #expect(lines == ["one", "two"])
    }

    @Test
    func emptyFileYieldsNoLines() throws {
        let lines = try lastLines(of: "", n: 5)
        #expect(lines.isEmpty)
    }

    @Test
    func nonPositiveCountYieldsNoLines() throws {
        let lines = try lastLines(of: "one\ntwo\n", n: 0)
        #expect(lines.isEmpty)
    }

    /// Lines longer than the internal read chunk must not be truncated, and the
    /// partial line left at a chunk boundary must not be reported as a line.
    @Test
    func handlesLinesLongerThanTheReadChunk() throws {
        let long = String(repeating: "x", count: 5000)
        let contents = "head\n\(long)\ntail\n"

        let lastTwo = try lastLines(of: contents, n: 2)
        #expect(lastTwo == [long, "tail"])

        let lastThree = try lastLines(of: contents, n: 3)
        #expect(lastThree == ["head", long, "tail"])
    }

    /// A chunk boundary can split a multi-byte UTF-8 sequence; the surviving
    /// lines must still decode correctly.
    @Test
    func handlesMultiByteCharactersAcrossChunkBoundaries() throws {
        let padded = String(repeating: "é", count: 2000)
        let contents = "\(padded)\nlast\n"

        let lastOne = try lastLines(of: contents, n: 1)
        #expect(lastOne == ["last"])

        let lastTwo = try lastLines(of: contents, n: 2)
        #expect(lastTwo == [padded, "last"])
    }
}
