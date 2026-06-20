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
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let internetFormatter = ISO8601DateFormatter()
        internetFormatter.formatOptions = [.withInternetDateTime]

        return fractionalFormatter.date(from: value)
            ?? internetFormatter.date(from: value)
            ?? parseLayoutTimestamp(value)
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
        guard !value.isEmpty, !value.hasPrefix("-") else {
            return nil
        }

        var total: TimeInterval = 0
        var index = value.startIndex
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

        return parsedComponent ? total : nil
    }

    private static func parseLayoutTimestamp(_ value: String) -> Date? {
        for format in timestampLayouts {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

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
}
