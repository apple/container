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
@testable import ContainerAPIService
import ContainerXPC
import Foundation
import Testing

struct ContainerLogsTests {

    @Test("Log filtering can return output larger than a pipe buffer")
    func testFilterLargeOutput() throws {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let line = "2027-01-01T00:00:00Z retained log line with enough bytes to grow the output\n"
        let content = String(repeating: line, count: 2_000)
        let handle = try fileHandle(containing: Data(content.utf8))

        let filtered = ContainersService.filterFileHandleSince(handle, since: since)
        let data = try #require(try filtered.readToEnd())

        #expect(data == Data(content.utf8))
    }

    @Test("Log filtering preserves empty lines and trailing newline")
    func testFilterPreservesEmptyLinesAndTrailingNewline() throws {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let content = "2020-01-01T00:00:00Z old\n\n2027-01-01T00:00:00Z new\n"
        let expected = "\n2027-01-01T00:00:00Z new\n"

        let data = try #require(ContainersService.filteredLogData(Data(content.utf8), since: since))

        #expect(String(data: data, encoding: .utf8) == expected)
    }

    @Test("Non-UTF8 logs fall back to the original bytes")
    func testNonUTF8LogsReturnOriginalBytes() throws {
        let bytes = Data([0xff, 0xfe, 0x00, 0x41])
        let handle = try fileHandle(containing: bytes)

        let filtered = ContainersService.filterFileHandleSince(handle, since: Date())
        let data = try #require(try filtered.readToEnd())

        #expect(data == bytes)
    }

    @Test("Harness preserves explicit epoch log since option")
    func testHarnessPreservesEpochSince() {
        let message = XPCMessage(route: .containerLogs)
        let epoch = Date(timeIntervalSince1970: 0)
        message.set(key: .logSince, value: epoch)

        let options = ContainersHarness.logOptions(from: message)

        #expect(options.since == epoch)
    }

    @Test("Harness preserves explicit pre-epoch log since option")
    func testHarnessPreservesPreEpochSince() {
        let message = XPCMessage(route: .containerLogs)
        let preEpoch = Date(timeIntervalSince1970: -1)
        message.set(key: .logSince, value: preEpoch)

        let options = ContainersHarness.logOptions(from: message)

        #expect(options.since == preEpoch)
    }

    @Test("Harness leaves absent log since option unset")
    func testHarnessLeavesAbsentSinceUnset() {
        let message = XPCMessage(route: .containerLogs)
        message.set(key: .logTimestamps, value: true)

        let options = ContainersHarness.logOptions(from: message)

        #expect(options.since == nil)
        #expect(options.timestamps)
    }

    private func fileHandle(containing data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("container-log-test-")
            .appendingPathExtension(UUID().uuidString)
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try? FileManager.default.removeItem(at: url)
        return handle
    }
}
