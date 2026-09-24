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

/// This is a thin wrapper around Measurement<UnitInformationStorage> to enable
/// better Codable implementations for user provided options. With this wrapper
/// values will get encoded and decoded from the format "1g" or "10mb".
public struct MemorySize: Codable, Sendable, Equatable, CustomStringConvertible {
    public var description: String { formatted }

    public let measurement: Measurement<UnitInformationStorage>

    public init(_ string: String) throws {
        self.measurement = try .parse(parsing: string)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(string)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formatted)
    }

    /// Unit labels ordered largest first, so that a size can be stepped down to the
    /// largest unit that still expresses it as a whole number.
    private static let unitLabels: [(unit: UnitInformationStorage, label: String)] = [
        (.pebibytes, "pb"),
        (.tebibytes, "tb"),
        (.gibibytes, "gb"),
        (.mebibytes, "mb"),
        (.kibibytes, "kb"),
        (.bytes, "b"),
    ]

    public var formatted: String {
        // This is what `encode(to:)` writes, so it has to parse back into the same size.
        // A whole value keeps the unit it was given; a fractional one steps down to a
        // smaller unit, because truncating it here shrinks the persisted configuration.
        guard let start = Self.unitLabels.firstIndex(where: { $0.unit == measurement.unit }) else {
            return "\(Int64(measurement.value))unknown"
        }
        for entry in Self.unitLabels[start...] {
            let value = measurement.converted(to: entry.unit).value
            if value == value.rounded() {
                return "\(Int64(value))\(entry.label)"
            }
        }
        return "\(Int64(measurement.converted(to: .bytes).value.rounded()))b"
    }
}

extension MemorySize {
    public func toUInt64(unit: UnitInformationStorage) -> UInt64 {
        UInt64(self.measurement.converted(to: unit).value.rounded())
    }
}
