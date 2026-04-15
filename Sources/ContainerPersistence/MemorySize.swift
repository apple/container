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
        let value = Int64(measurement.value)
        let label = Self.unitLabels[measurement.unit] ?? "unknown"
        return "\(value)\(label)"
    }
}
