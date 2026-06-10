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

struct VolumeConfigurationTests {

    func makeConfiguration(name: String = "test-volume", creationDate: Date = Date()) -> VolumeConfiguration {
        VolumeConfiguration(
            name: name,
            driver: "local",
            format: "ext4",
            source: "/volumes/\(name)/volume.img",
            creationDate: creationDate,
            labels: ["env": "test"],
            options: ["size": "1GiB"],
            sizeInBytes: 1_073_741_824
        )
    }

    @Test func testEncodesCreationDateKey() throws {
        let config = makeConfiguration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try String(data: encoder.encode(config), encoding: .utf8)!

        #expect(json.contains("\"creationDate\""), "encoded JSON should use creationDate key")
        #expect(!json.contains("\"createdAt\""), "encoded JSON must not use deprecated createdAt key")
    }

    @Test func testRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = makeConfiguration(creationDate: date)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VolumeConfiguration.self, from: encoder.encode(original))

        #expect(decoded.name == original.name)
        #expect(decoded.driver == original.driver)
        #expect(decoded.format == original.format)
        #expect(decoded.source == original.source)
        #expect(decoded.creationDate.timeIntervalSince1970 == original.creationDate.timeIntervalSince1970)
        #expect(decoded.labels == original.labels)
        #expect(decoded.options == original.options)
        #expect(decoded.sizeInBytes == original.sizeInBytes)
    }

    @Test func testDecodesLegacyCreatedAtKey() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyJSON = """
            {
                "name": "test-volume",
                "driver": "local",
                "format": "ext4",
                "source": "/volumes/test-volume/volume.img",
                "createdAt": \(date.timeIntervalSinceReferenceDate),
                "labels": {},
                "options": {}
            }
            """

        let decoder = JSONDecoder()
        let config = try decoder.decode(VolumeConfiguration.self, from: Data(legacyJSON.utf8))

        #expect(config.name == "test-volume")
        #expect(config.creationDate.timeIntervalSince1970 == date.timeIntervalSince1970)
    }

    @Test func testMissingDateDefaultsToEpoch() throws {
        let json = """
            {
                "name": "test-volume",
                "driver": "local",
                "format": "ext4",
                "source": "/volumes/test-volume/volume.img",
                "labels": {},
                "options": {}
            }
            """

        let config = try JSONDecoder().decode(VolumeConfiguration.self, from: Data(json.utf8))
        #expect(config.creationDate.timeIntervalSince1970 == 0)
    }
}
