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

import ContainerPersistence
import Foundation
import Testing

struct MemorySizeTests {
    @Test(arguments: [
        ("1gb", "1gb"),
        ("2048MB", "2048mb"),
        ("512kb", "512kb"),
        ("1024b", "1024b"),
        ("4tb", "4tb"),
    ])
    func testFormattedOutput(input: String, expected: String) throws {
        let size = try MemorySize(input)
        #expect(size.formatted == expected)
    }

    @Test func testMeasurementValue() throws {
        let size = try MemorySize("2048mb")
        #expect(size.measurement.value == 2048)
        #expect(size.measurement.unit == .mebibytes)

        let sizeGB = try MemorySize("4gb")
        #expect(sizeGB.measurement.value == 4)
        #expect(sizeGB.measurement.unit == .gibibytes)
    }

    @Test func testDescription() throws {
        let size = try MemorySize("1gb")
        #expect(size.description == "1gb")
    }

    @Test func testEquality() throws {
        let a = try MemorySize("1gb")
        let b = try MemorySize("1gb")
        #expect(a == b)
    }

    @Test func testRoundTripEncoding() throws {
        let original = try MemorySize("2048mb")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MemorySize.self, from: data)
        #expect(original == decoded)
    }

    @Test func testDecodingFromString() throws {
        let json = Data("\"512kb\"".utf8)
        let decoded = try JSONDecoder().decode(MemorySize.self, from: json)
        #expect(decoded.formatted == "512kb")
    }

    @Test func testInvalidInputThrows() throws {
        #expect(throws: (any Error).self) {
            _ = try MemorySize("notasize")
        }
    }
}
