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

/// Parses log timestamp filters accepted by Docker-compatible log commands.
public struct ContainerLogTimestampParser: Sendable {
    /// Parses absolute timestamps, Unix timestamps, or relative durations.
    public static func parse(_ value: String, relativeTo now: Date = Date()) -> Date? {
        parseAbsoluteTimestamp(value)
            ?? parseUnixTimestamp(value)
            ?? parseDuration(value).map { now.addingTimeInterval(-$0) }
    }

    /// Parses an absolute timestamp without interpreting relative durations.
    public static func parseAbsoluteTimestamp(_ value: String) -> Date? {
        absoluteTimestampParser.parse(value)
    }

    /// Parses a timestamp token that was read from a stored log record prefix.
    ///
    /// CLI filter arguments intentionally accept Docker-compatible local dates,
    /// Unix timestamps, and relative durations. Runtime-authored log prefixes
    /// need a stricter boundary: only RFC 3339-style timestamps with explicit
    /// timezone information are treated as record timestamps.
    public static func parseRecordTimestampPrefix(_ value: String) -> Date? {
        recordTimestampPrefixParser.parse(value)
    }

    /// Parses a Unix timestamp with optional fractional seconds.
    public static func parseUnixTimestamp(_ value: String) -> Date? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
            let secondsPart = parts.first,
            !secondsPart.isEmpty,
            secondsPart.allSatisfy(\.isNumber),
            let seconds = TimeInterval(String(secondsPart)),
            seconds.isFinite,
            seconds >= 0
        else {
            return nil
        }

        var fractionalSeconds: TimeInterval = 0
        if parts.count == 2 {
            let fractionPart = parts[1]
            guard !fractionPart.isEmpty,
                fractionPart.count <= 9,
                fractionPart.allSatisfy(\.isNumber),
                let fraction = TimeInterval("0.\(fractionPart)")
            else {
                return nil
            }
            fractionalSeconds = fraction
        }

        return Date(timeIntervalSince1970: seconds + fractionalSeconds)
    }

    /// Parses Go-style durations such as `1m30s`, `250ms`, and `1.5h`.
    public static func parseDuration(_ value: String) -> TimeInterval? {
        guard !value.isEmpty else {
            return nil
        }

        var sign: TimeInterval = 1
        var index = value.startIndex
        if value[index] == "-" {
            sign = -1
            index = value.index(after: index)
        } else if value[index] == "+" {
            index = value.index(after: index)
        }
        guard index < value.endIndex else {
            return nil
        }

        var total: TimeInterval = 0
        var parsedComponent = false

        while index < value.endIndex {
            let numberStart = index
            var seenDecimalPoint = false
            while index < value.endIndex {
                let character = value[index]
                if character.isNumber {
                    index = value.index(after: index)
                } else if character == ".", !seenDecimalPoint {
                    seenDecimalPoint = true
                    index = value.index(after: index)
                } else {
                    break
                }
            }

            guard numberStart < index,
                let amount = TimeInterval(value[numberStart..<index]),
                amount.isFinite
            else {
                return nil
            }

            let unitStart = index
            while index < value.endIndex, value[index].isLetter || value[index] == "µ" || value[index] == "μ" {
                index = value.index(after: index)
            }
            let unit = String(value[unitStart..<index])
            guard let multiplier = durationMultiplier(unit) else {
                return nil
            }
            let component = amount * multiplier
            guard component.isFinite else {
                return nil
            }
            total += component
            guard total.isFinite else {
                return nil
            }
            parsedComponent = true
        }

        return parsedComponent ? total * sign : nil
    }

    private static let absoluteTimestampParser = AbsoluteTimestampParser()
    private static let recordTimestampPrefixParser = RecordTimestampPrefixParser()

    private static let timestampLayouts = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mmXXXXX",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd",
    ]

    private static func durationMultiplier(_ unit: String) -> TimeInterval? {
        switch unit {
        case "ns":
            return 0.000_000_001
        case "us", "µs", "μs":
            return 0.000_001
        case "ms":
            return 0.001
        case "s":
            return 1
        case "m":
            return 60
        case "h":
            return 60 * 60
        default:
            return nil
        }
    }

    private final class RecordTimestampPrefixParser: @unchecked Sendable {
        private let lock = NSLock()
        private let fractionalFormatter: ISO8601DateFormatter
        private let internetFormatter: ISO8601DateFormatter

        init() {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fractionalFormatter = fractionalFormatter

            let internetFormatter = ISO8601DateFormatter()
            internetFormatter.formatOptions = [.withInternetDateTime]
            self.internetFormatter = internetFormatter
        }

        func parse(_ value: String) -> Date? {
            guard Self.hasExplicitTimeZone(in: value) else {
                return nil
            }

            lock.lock()
            defer {
                lock.unlock()
            }

            return fractionalFormatter.date(from: value)
                ?? internetFormatter.date(from: value)
        }

        private static func hasExplicitTimeZone(in value: String) -> Bool {
            guard let timeSeparator = value.firstIndex(of: "T") else {
                return false
            }

            let timeStart = value.index(after: timeSeparator)
            let timePart = value[timeStart..<value.endIndex]
            if timePart.hasSuffix("Z") {
                return true
            }

            guard let offsetStart = timePart.lastIndex(where: { $0 == "+" || $0 == "-" }) else {
                return false
            }

            let offset = timePart[offsetStart..<timePart.endIndex]
            guard offset.count == 6 else {
                return false
            }

            let hourStart = offset.index(after: offsetStart)
            let colonIndex = offset.index(hourStart, offsetBy: 2)
            let minuteStart = offset.index(after: colonIndex)

            return offset[colonIndex] == ":"
                && offset[hourStart..<colonIndex].allSatisfy(\.isNumber)
                && offset[minuteStart..<offset.endIndex].allSatisfy(\.isNumber)
        }
    }

    private final class AbsoluteTimestampParser: @unchecked Sendable {
        private let lock = NSLock()
        private let fractionalFormatter: ISO8601DateFormatter
        private let internetFormatter: ISO8601DateFormatter
        private let layoutFormatters: [DateFormatter]

        init() {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fractionalFormatter = fractionalFormatter

            let internetFormatter = ISO8601DateFormatter()
            internetFormatter.formatOptions = [.withInternetDateTime]
            self.internetFormatter = internetFormatter

            self.layoutFormatters = timestampLayouts.map { format in
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                return formatter
            }
        }

        func parse(_ value: String) -> Date? {
            lock.lock()
            defer {
                lock.unlock()
            }

            return fractionalFormatter.date(from: value)
                ?? internetFormatter.date(from: value)
                ?? parseLayoutTimestamp(value)
        }

        private func parseLayoutTimestamp(_ value: String) -> Date? {
            for formatter in layoutFormatters {
                formatter.timeZone = TimeZone.current
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            return nil
        }
    }
}
