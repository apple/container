//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

private let binaryUnits: [Character: UnitInformationStorage] = [
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

    /// parseMemory the provided string into a measurement that is able to be converted to various byte sizes using binary exponents
    public static func parse(parsing: String) throws -> Measurement<UnitInformationStorage> {
        let check = "01234567890."
        let trimmed = parsing.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else {
            throw ParseError.invalidSize
        }

        let i = trimmed.firstIndex {
            !check.contains($0)
        }
        let rawValue =
            i
            .map { trimmed[..<$0].trimmingCharacters(in: .whitespaces) }
            ?? trimmed
        let rawUnit = i.map { trimmed[$0...].trimmingCharacters(in: .whitespaces) } ?? ""

        let value = Double(rawValue)
        guard let value else {
            throw ParseError.invalidSize
        }
        let unitSymbol = try Self.parseUnit(rawUnit)

        let unit = binaryUnits[unitSymbol]
        guard let unit else {
            throw ParseError.invalidSymbol(rawUnit)
        }
        return Measurement<UnitInformationStorage>(value: value, unit: unit)
    }

    static func parseUnit(_ unit: String) throws -> Character {
        let s = unit.dropFirst()
        let unitSymbol = unit.first ?? "b"

        switch s {
        case "", "ib", "b":
            return unitSymbol
        default:
            throw ParseError.invalidSymbol(unit)
        }
    }
}
