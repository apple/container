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
import Testing

@testable import ContainerClient

struct MeasurementParseTests {

    @Test("Parse binary units - bare unit symbols")
    func testBinaryUnits() throws {
        let result1 = try Measurement<UnitInformationStorage>.parse(parsing: "4k")
        #expect(result1.value == 4.0)
        #expect(result1.unit == .kibibytes)

        let result2 = try Measurement<UnitInformationStorage>.parse(parsing: "2m")
        #expect(result2.value == 2.0)
        #expect(result2.unit == .mebibytes)

        let result3 = try Measurement<UnitInformationStorage>.parse(parsing: "1g")
        #expect(result3.value == 1.0)
        #expect(result3.unit == .gibibytes)

        let result4 = try Measurement<UnitInformationStorage>.parse(parsing: "512b")
        #expect(result4.value == 512.0)
        #expect(result4.unit == .bytes)
    }

    @Test("Parse binary units - ib suffix")
    func testBinaryUnitsWithIbSuffix() throws {
        let result1 = try Measurement<UnitInformationStorage>.parse(parsing: "4kib")
        #expect(result1.value == 4.0)
        #expect(result1.unit == .kibibytes)

        let result2 = try Measurement<UnitInformationStorage>.parse(parsing: "2mib")
        #expect(result2.value == 2.0)
        #expect(result2.unit == .mebibytes)

        let result3 = try Measurement<UnitInformationStorage>.parse(parsing: "1gib")
        #expect(result3.value == 1.0)
        #expect(result3.unit == .gibibytes)

        let result4 = try Measurement<UnitInformationStorage>.parse(parsing: "3tib")
        #expect(result4.value == 3.0)
        #expect(result4.unit == .tebibytes)

        let result5 = try Measurement<UnitInformationStorage>.parse(parsing: "1pib")
        #expect(result5.value == 1.0)
        #expect(result5.unit == .pebibytes)
    }

    @Test("Parse binary units - all suffixes now use binary")
    func testAllSuffixesUseBinary() throws {
        let result1 = try Measurement<UnitInformationStorage>.parse(parsing: "4kb")
        #expect(result1.value == 4.0)
        #expect(result1.unit == .kibibytes)

        let result2 = try Measurement<UnitInformationStorage>.parse(parsing: "2mb")
        #expect(result2.value == 2.0)
        #expect(result2.unit == .mebibytes)

        let result3 = try Measurement<UnitInformationStorage>.parse(parsing: "1gb")
        #expect(result3.value == 1.0)
        #expect(result3.unit == .gibibytes)

        let result4 = try Measurement<UnitInformationStorage>.parse(parsing: "3tb")
        #expect(result4.value == 3.0)
        #expect(result4.unit == .tebibytes)

        let result5 = try Measurement<UnitInformationStorage>.parse(parsing: "1pb")
        #expect(result5.value == 1.0)
        #expect(result5.unit == .pebibytes)
    }

    @Test("Parse with whitespace")
    func testParsingWithWhitespace() throws {
        let result1 = try Measurement<UnitInformationStorage>.parse(parsing: " 4k ")
        #expect(result1.value == 4.0)
        #expect(result1.unit == .kibibytes)

        let result2 = try Measurement<UnitInformationStorage>.parse(parsing: "  2.5mb  ")
        #expect(result2.value == 2.5)
        #expect(result2.unit == .mebibytes)
    }

    @Test("Parse decimal values")
    func testDecimalValues() throws {
        let result1 = try Measurement<UnitInformationStorage>.parse(parsing: "4.5k")
        #expect(result1.value == 4.5)
        #expect(result1.unit == .kibibytes)

        let result2 = try Measurement<UnitInformationStorage>.parse(parsing: "1.25gb")
        #expect(result2.value == 1.25)
        #expect(result2.unit == .gibibytes)

        let result3 = try Measurement<UnitInformationStorage>.parse(parsing: "0.5mib")
        #expect(result3.value == 0.5)
        #expect(result3.unit == .mebibytes)
    }

    @Test("Parse case insensitive")
    func testCaseInsensitive() throws {
        let result1 = try Measurement<UnitInformationStorage>.parse(parsing: "4K")
        #expect(result1.value == 4.0)
        #expect(result1.unit == .kibibytes)

        let result2 = try Measurement<UnitInformationStorage>.parse(parsing: "2GB")
        #expect(result2.value == 2.0)
        #expect(result2.unit == .gibibytes)

        let result3 = try Measurement<UnitInformationStorage>.parse(parsing: "1MIB")
        #expect(result3.value == 1.0)
        #expect(result3.unit == .mebibytes)
    }

    @Test("Parse bytes unit")
    func testBytesUnit() throws {
        let result1 = try Measurement<UnitInformationStorage>.parse(parsing: "1024")
        #expect(result1.value == 1024.0)
        #expect(result1.unit == .bytes)

        let result2 = try Measurement<UnitInformationStorage>.parse(parsing: "512b")
        #expect(result2.value == 512.0)
        #expect(result2.unit == .bytes)
    }

    @Test("Parse invalid size throws error")
    func testInvalidSizeThrowsError() {
        #expect {
            _ = try Measurement<UnitInformationStorage>.parse(parsing: "abc")
        } throws: { error in
            guard let parseError = error as? Measurement<UnitInformationStorage>.ParseError else {
                return false
            }
            return parseError.description == "invalid size"
        }

        #expect {
            _ = try Measurement<UnitInformationStorage>.parse(parsing: "k4")
        } throws: { error in
            guard let parseError = error as? Measurement<UnitInformationStorage>.ParseError else {
                return false
            }
            return parseError.description == "invalid size"
        }
    }

    @Test("Parse invalid symbol throws error")
    func testInvalidSymbolThrowsError() {
        #expect {
            _ = try Measurement<UnitInformationStorage>.parse(parsing: "4x")
        } throws: { error in
            guard let parseError = error as? Measurement<UnitInformationStorage>.ParseError else {
                return false
            }
            return parseError.description == "invalid symbol: x"
        }

        #expect {
            _ = try Measurement<UnitInformationStorage>.parse(parsing: "4kx")
        } throws: { error in
            guard let parseError = error as? Measurement<UnitInformationStorage>.ParseError else {
                return false
            }
            return parseError.description == "invalid symbol: kx"
        }
    }

    @Test("Parse empty string throws error")
    func testEmptyStringThrowsError() {
        #expect {
            _ = try Measurement<UnitInformationStorage>.parse(parsing: "")
        } throws: { error in
            guard let parseError = error as? Measurement<UnitInformationStorage>.ParseError else {
                return false
            }
            return parseError.description == "invalid size"
        }
    }

    @Test("Verify all suffixes now use binary units")
    func testAllSuffixesUseBinaryUnits() throws {
        let bareK = try Measurement<UnitInformationStorage>.parse(parsing: "1k")
        let kib = try Measurement<UnitInformationStorage>.parse(parsing: "1kib")
        let kb = try Measurement<UnitInformationStorage>.parse(parsing: "1kb")

        #expect(bareK.unit == .kibibytes)
        #expect(kib.unit == .kibibytes)
        #expect(kb.unit == .kibibytes)

        let allInBytes = bareK.converted(to: .bytes).value

        #expect(allInBytes == 1024.0)
    }
}
