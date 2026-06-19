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
            since: since,
            until: until
        )

        #expect(options.tail == 25)
        #expect(options.since == since.date)
        #expect(options.until == until.date)
    }

    @Test
    func logOptionsLeaveTailForLocalFollowHandling() {
        let options = Application.ContainerLogs.retrievalOptions(
            numLines: 25,
            follow: true,
            since: nil,
            until: nil
        )

        #expect(options.tail == nil)
        #expect(options.since == nil)
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

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
