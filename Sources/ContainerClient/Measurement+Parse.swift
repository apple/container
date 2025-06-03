//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

private let units: [Character: UnitInformationStorage] = [
    "b": .bytes,
    "k": .kibibytes,
    "m": .mebibytes,
    "g": .gibibytes,
    "t": .tebibytes,
    "p": .pebibytes,
]

extension Measurement {
    public enum ParseError: Swift.Error, CustomStringConvertible {
        case invalidSize
        case invalidSymbol(String)

        public var description: String {
            switch self {
            case .invalidSize:
                return "invalid size"
            case .invalidSymbol(let symbol):
                return "invalid symbol: \(symbol)"
            }
        }
    }

    /// parse the provided string into a measurement that is able to be converted to various byte sizes
    public static func parse(parsing: String) throws -> Measurement<UnitInformationStorage> {
        let check = "01234567890. "
        let i = parsing.lastIndex {
            check.contains($0)
        }
        guard let i else {
            throw ParseError.invalidSize
        }
        let after = parsing.index(after: i)
        let rawValue = parsing[..<after].trimmingCharacters(in: .whitespaces)
        let rawUnit = parsing[after...]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        let value = Double(rawValue)
        guard let value else {
            throw ParseError.invalidSize
        }
        let unitSymbol = try Self.parseUnit(rawUnit)

        let unit = units[unitSymbol]
        guard let unit else {
            throw ParseError.invalidSymbol(rawUnit)
        }
        return Measurement<UnitInformationStorage>(value: value, unit: unit)
    }

    static func parseUnit(_ unit: String) throws -> Character {
        let s = unit.dropFirst()
        switch s {
        case "", "b", "ib":
            return unit.first ?? "b"
        default:
            throw ParseError.invalidSymbol(unit)
        }
    }
}
