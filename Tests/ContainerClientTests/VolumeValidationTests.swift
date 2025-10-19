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

struct VolumeValidationTests {

    @Test("Valid volume names should pass validation")
    func testValidVolumeNames() {
        let validNames = [
            "a",  // Single alphanumeric
            "1",  // Single numeric
            "volume1",  // Alphanumeric
            "my-volume",  // With hyphen
            "my_volume",  // With underscore
            "my.volume",  // With period
            "volume-1.2_test",  // Mixed valid characters
            "1volume",  // Starting with number
            "Avolume",  // Starting with uppercase
            "a" + String(repeating: "x", count: 254),  // Max length (255)
        ]

        for name in validNames {
            #expect(VolumeStorage.isValidVolumeName(name), "'\(name)' should be valid")
        }
    }

    @Test("Invalid volume names should fail validation")
    func testInvalidVolumeNames() {
        let invalidNames = [
            "",  // Empty string
            ".volume",  // Starting with period
            "_volume",  // Starting with underscore
            "-volume",  // Starting with hyphen
            "volume@",  // Contains invalid character (@)
            "volume space",  // Contains space
            "volume/path",  // Contains slash
            "volume:tag",  // Contains colon
            "volume#hash",  // Contains hash
            "volume$",  // Contains dollar sign
            "volume!",  // Contains exclamation
            "volume%",  // Contains percent
            "volume*",  // Contains asterisk
            "volume+",  // Contains plus
            "volume=",  // Contains equals
            "volume[",  // Contains bracket
            "volume]",  // Contains bracket
            "volume{",  // Contains brace
            "volume}",  // Contains brace
            "volume|",  // Contains pipe
            "volume\\",  // Contains backslash
            "volume\"",  // Contains quote
            "volume'",  // Contains single quote
            "volume<",  // Contains less than
            "volume>",  // Contains greater than
            "volume?",  // Contains question mark
            "volume,",  // Contains comma
            "volume;",  // Contains semicolon
            "a" + String(repeating: "x", count: 255),  // Too long (256 chars)
        ]

        for name in invalidNames {
            #expect(!VolumeStorage.isValidVolumeName(name), "'\(name)' should be invalid")
        }
    }

    @Test("Edge cases for volume name validation")
    func testVolumeNameEdgeCases() {
        // Test exact boundary conditions
        #expect(VolumeStorage.isValidVolumeName("a"), "Single character should be valid")
        #expect(!VolumeStorage.isValidVolumeName(""), "Empty string should be invalid")

        // Test maximum length boundary
        let maxLengthName = String(repeating: "a", count: 255)
        let tooLongName = String(repeating: "a", count: 256)
        #expect(VolumeStorage.isValidVolumeName(maxLengthName), "255 character name should be valid")
        #expect(!VolumeStorage.isValidVolumeName(tooLongName), "256 character name should be invalid")

        // Test other edge cases
        #expect(VolumeStorage.isValidVolumeName("0volume"), "Name starting with digit should be valid")
        #expect(VolumeStorage.isValidVolumeName("Volume"), "Name starting with uppercase should be valid")
        #expect(!VolumeStorage.isValidVolumeName(".hidden"), "Name starting with period should be invalid")
        #expect(!VolumeStorage.isValidVolumeName("_private"), "Name starting with underscore should be invalid")
        #expect(!VolumeStorage.isValidVolumeName("-dash"), "Name starting with hyphen should be invalid")
    }

    @Test("Unicode and special character handling")
    func testUnicodeCharacters() {
        let unicodeNames = [
            "volume-ñ",  // Non-ASCII letter
            "volume-中文",  // Chinese characters
            "volume-🍎",  // Emoji
            "volume-café",  // Accented characters
            "αβγ",  // Greek letters
        ]

        for name in unicodeNames {
            #expect(!VolumeStorage.isValidVolumeName(name), "Unicode name '\(name)' should be invalid")
        }
    }

    @Test("Common Container volume name patterns")
    func testCommonVolumeNames() {
        let commonPatterns = [
            "myapp-data",  // Common app data volume
            "postgres_data",  // Database volume
            "nginx.conf",  // Config volume
            "logs-2024",  // Log volume with year
            "cache_redis_v1.2",  // Version-tagged cache
            "backup.daily",  // Backup volume
            "shared-storage",  // Shared volume
        ]

        for name in commonPatterns {
            #expect(VolumeStorage.isValidVolumeName(name), "Common volume name pattern '\(name)' should be valid")
        }
    }
}
