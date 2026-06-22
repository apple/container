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

struct ContainerLogsCommandTests {
    @Test
    func parsesRFC3339Timestamp() throws {
        let timestamp = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))

        #expect(timestamp.date == date("2026-06-18T10:00:00Z"))
    }

    @Test
    func parsesFractionalRFC3339Timestamp() throws {
        let timestamp = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00.123Z"))

        #expect(timestamp.date == date("2026-06-18T10:00:00.123Z"))
    }

    @Test
    func rejectsInvalidTimestamp() {
        #expect(ContainerLogTimestamp(argument: "not-a-date") == nil)
    }

    @Test
    func logOptionsUseAPITailWhenNotFollowing() throws {
        let since = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))
        let until = try #require(ContainerLogTimestamp(argument: "2026-06-18T11:00:00Z"))

        let options = Application.ContainerLogs.retrievalOptions(
            numLines: 25,
            follow: false,
            boot: false,
            since: since,
            until: until
        )

        #expect(options.tail == 25)
        #expect(options.since == since.date)
        #expect(options.until == until.date)
        #expect(options.stream == .stdio)
    }

    @Test
    func logOptionsLeaveTailForLocalFollowHandling() {
        let options = Application.ContainerLogs.retrievalOptions(
            numLines: 25,
            follow: true,
            boot: false,
            since: nil,
            until: nil
        )

        #expect(options.tail == nil)
        #expect(options.since == nil)
        #expect(options.until == nil)
        #expect(options.stream == .stdio)
    }

    @Test
    func logOptionsSelectBootStream() {
        let options = Application.ContainerLogs.retrievalOptions(
            numLines: nil,
            follow: false,
            boot: true,
            since: nil,
            until: nil
        )

        #expect(options.stream == .boot)
    }

    @Test
    func validateRejectsFollowWithSince() throws {
        let since = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))

        #expect(throws: Error.self) {
            try Application.ContainerLogs.validateLogOptions(follow: true, since: since, until: nil)
        }
    }

    @Test
    func validateRejectsFollowWithUntil() throws {
        let until = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))

        #expect(throws: Error.self) {
            try Application.ContainerLogs.validateLogOptions(follow: true, since: nil, until: until)
        }
    }

    @Test
    func validateAcceptsFollowWithTailOnly() throws {
        try Application.ContainerLogs.validateLogOptions(follow: true, since: nil, until: nil)
    }

    @Test
    func logFileOutputNegativeTailWritesAllBytes() async throws {
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let inputHandle = try fileHandle(containing: Data("one\ntwo\n".utf8))
        defer { try? inputHandle.close() }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        try await LogFileOutput.write(fh: inputHandle, n: -1, follow: false, output: outputHandle)
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "one\ntwo\n")
    }

    @Test
    func logFileOutputWritesAllBytesWithoutUTF8Decoding() async throws {
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])

        let inputHandle = try fileHandle(containing: bytes)
        defer { try? inputHandle.close() }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        try await LogFileOutput.write(fh: inputHandle, n: nil, follow: false, output: outputHandle)
        try outputHandle.close()

        #expect(try Data(contentsOf: outputURL) == bytes)
    }

    @Test
    func logFileOutputTailDataPreservesBlankLinesAndTrailingNewline() {
        let data = Data("one\n\ntwo\n".utf8)

        let tail = LogFileOutput.tailData(data, lineCount: 2)

        #expect(String(data: tail, encoding: .utf8) == "\ntwo\n")
    }

    @Test
    func logFileOutputZeroTailReturnsEmptyData() {
        let data = Data("one\ntwo\n".utf8)

        let tail = LogFileOutput.tailData(data, lineCount: 0)

        #expect(tail.isEmpty)
    }

    private func fileHandle(containing data: Data) throws -> FileHandle {
        let url = temporaryFileURL()
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try? FileManager.default.removeItem(at: url)
        return handle
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-command-test-\(UUID().uuidString)")
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
