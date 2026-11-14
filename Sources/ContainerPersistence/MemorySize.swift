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

    private static let unitLabels: [UnitInformationStorage: String] = [
        .bytes: "b",
        .kibibytes: "kb",
        .mebibytes: "mb",
        .gibibytes: "gb",
        .tebibytes: "tb",
        .pebibytes: "pb",
    ]

    public var formatted: String {
        // Only whole-number sizes can be represented in the stored unit without
        // loss. A fractional value (e.g. "1.5gb") would truncate to "1gb" and
        // silently drop memory when re-encoded, so emit the exact byte count
        // instead. Binary units are integer multiples of a byte, so this keeps
        // the encode/decode round-trip lossless while leaving whole-number
        // output (e.g. "1gb", "2048mb") unchanged.
        guard measurement.value == measurement.value.rounded() else {
            let bytes = UInt64(measurement.converted(to: .bytes).value.rounded())
            return "\(bytes)\(Self.unitLabels[.bytes] ?? "b")"
        }
        let value = Int64(measurement.value)
        let label = Self.unitLabels[measurement.unit] ?? "unknown"
        return "\(value)\(label)"
    }
}

extension MemorySize {
    public func toUInt64(unit: UnitInformationStorage) -> UInt64 {
        UInt64(self.measurement.converted(to: unit).value.rounded())
    }
}
