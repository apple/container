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

import ContainerAPIClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerLogsTests {
    @Test func filtersLogsBySinceUntilAndTail() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z first
            2026-01-03T00:00:00Z second
            2026-01-04T00:00:00Z new

            """
        let options = ContainerLogOptions(
            tail: 1,
            since: date("2026-01-02T00:00:00Z"),
            until: date("2026-01-03T00:00:00Z")
        )

        let data = try ContainersService.filteredLogData(Data(content.utf8), options: options)

        #expect(String(data: data, encoding: .utf8) == "2026-01-03T00:00:00Z second\n")
    }

    @Test func timeFiltersRejectUnparseableLines() throws {
        let content = """
            2026-01-01T00:00:00Z old
            unparseable

            2026-01-03T00:00:00Z retained

            """
        let options = ContainerLogOptions(
            since: date("2026-01-02T00:00:00Z")
        )

        #expect {
            _ = try ContainersService.filteredLogData(Data(content.utf8), options: options)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.code == .invalidArgument
        }
    }

    @Test func tailOnlyPreservesUnparseableLinesEmptyLinesAndTrailingNewline() throws {
        let content = "unparseable\n\nretained\n"

        let data = try ContainersService.filteredLogData(Data(content.utf8), options: ContainerLogOptions(tail: -1))

        #expect(String(data: data, encoding: .utf8) == content)
    }

    @Test func tailZeroReturnsEmptyLogData() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z new

            """

        let data = try ContainersService.filteredLogData(Data(content.utf8), options: ContainerLogOptions(tail: 0))

        #expect(data.isEmpty)
    }

    @Test func negativeTailDoesNotDropLogs() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z new

            """

        let data = try ContainersService.filteredLogData(Data(content.utf8), options: ContainerLogOptions(tail: -1))

        #expect(String(data: data, encoding: .utf8) == content)
    }

    @Test func nonUTF8LogsCanBeTailedWithoutDecoding() throws {
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])
        let data = try ContainersService.filteredLogData(bytes, options: ContainerLogOptions(tail: 1))

        #expect(data == Data([0x41, 0x0a]))
    }

    @Test func nonUTF8LogsApplyTailWhenOpeningFilteredHandle() throws {
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])
        let handle = try fileHandle(containing: bytes)

        let filtered = try ContainersService.applyLogOptions(to: handle, options: ContainerLogOptions(tail: 1))
        defer { try? filtered.close() }
        let data = try #require(try filtered.readToEnd())

        #expect(data == Data([0x41, 0x0a]))
    }

    @Test func nonUTF8LogsRejectTimeFilters() throws {
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])

        #expect {
            _ = try ContainersService.filteredLogData(bytes, options: ContainerLogOptions(since: date("2026-01-01T00:00:00Z")))
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.code == .invalidArgument
        }
    }

    @Test func filteredHandleCreationFailureThrows() throws {
        let handle = try fileHandle(containing: Data("one\ntwo\n".utf8))
        defer { try? handle.close() }
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-test-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockedDirectory)
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }

        #expect(throws: Error.self) {
            _ = try ContainersService.applyLogOptions(
                to: handle,
                options: ContainerLogOptions(tail: 1),
                temporaryDirectory: blockedDirectory
            )
        }
    }

    @Test func emptyLogsApplyTimeFiltersWithoutThrowing() throws {
        let handle = try fileHandle(containing: Data())

        let filtered = try ContainersService.applyLogOptions(
            to: handle,
            options: ContainerLogOptions(since: date("2026-01-01T00:00:00Z"))
        )
        defer { try? filtered.close() }
        let data = try filtered.readToEnd() ?? Data()

        #expect(data.isEmpty)
    }

    @Test func boundedTailPreservesLongLogicalLine() throws {
        let longLine = String(repeating: "x", count: 40_000)
        let handle = try fileHandle(containing: Data("old\n\(longLine)\ntwo\n".utf8))
        defer { try? handle.close() }

        let data = try ContainersService.tailLogData(from: handle, lineCount: 2)

        #expect(String(data: data, encoding: .utf8) == "\(longLine)\ntwo\n")
    }

    @Test func harnessDecodesLogOptions() {
        let message = XPCMessage(route: .containerLogs)
        let since = Date(timeIntervalSince1970: 0)
        let until = Date(timeIntervalSince1970: -1)
        message.set(key: .logTail, value: Int64(0))
        message.set(key: .logSince, value: since)
        message.set(key: .logUntil, value: until)
        message.set(key: .logTimestamps, value: true)

        let options = ContainersHarness.logOptions(from: message)

        #expect(options.tail == 0)
        #expect(options.since == since)
        #expect(options.until == until)
        #expect(options.timestamps)
    }

    @Test func harnessLeavesAbsentLogOptionsUnset() {
        let message = XPCMessage(route: .containerLogs)

        let options = ContainersHarness.logOptions(from: message)

        #expect(options.tail == nil)
        #expect(options.since == nil)
        #expect(options.until == nil)
        #expect(!options.timestamps)
    }

    private func fileHandle(containing data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-test-\(UUID().uuidString)")
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try? FileManager.default.removeItem(at: url)
        return handle
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
