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

@testable import ContainerResource

@Suite(.serialized)
struct ContainerLogOptionsTests {
    @Test func defaultOptionsPreserveExistingBehavior() {
        let options = ContainerLogOptions.default

        #expect(options.tail == nil)
        #expect(options.since == nil)
        #expect(options.until == nil)
        #expect(!options.timestamps)
        #expect(options.stream == nil)
    }

    @Test func customOptionsRoundTripThroughJSON() throws {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let until = Date(timeIntervalSince1970: 1_900_000_000)
        let options = ContainerLogOptions(
            tail: 100,
            since: since,
            until: until,
            timestamps: true,
            stream: .boot
        )

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ContainerLogOptions.self, from: data)

        #expect(decoded == options)
    }

    @Test func parsesDockerCompatibleLogTimestamps() throws {
        let reference = Date(timeIntervalSince1970: 1_900_000_000)

        #expect(ContainerLogTimestampParser.parse("2026-06-18T10:00:00Z") == date("2026-06-18T10:00:00Z"))
        #expect(ContainerLogTimestampParser.parse("2026-06-18T10:00:00.123456789Z") != nil)
        #expect(ContainerLogTimestampParser.parse("1781776800.25") == Date(timeIntervalSince1970: 1_781_776_800.25))
        #expect(ContainerLogTimestampParser.parse("1m30s", relativeTo: reference) == reference.addingTimeInterval(-90))
        #expect(ContainerLogTimestampParser.parse("250ms", relativeTo: reference) == reference.addingTimeInterval(-0.25))
        #expect(ContainerLogTimestampParser.parse("1.5h", relativeTo: reference) == reference.addingTimeInterval(-5_400))
    }

    @Test func parsesDateOnlyLogTimestampInLocalTime() throws {
        let previousTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 3_600)!
        defer { NSTimeZone.default = previousTimeZone }

        let timestamp = try #require(ContainerLogTimestampParser.parse("2026-06-18"))

        #expect(timestamp == localDate("2026-06-18"))
    }

    @Test func rejectsInvalidLogTimestamps() {
        #expect(ContainerLogTimestampParser.parse("not-a-date") == nil)
        #expect(ContainerLogTimestampParser.parse("-1s") == nil)
        #expect(ContainerLogTimestampParser.parse("1781776800.") == nil)
        #expect(ContainerLogTimestampParser.parse("1d") == nil)
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func localDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
