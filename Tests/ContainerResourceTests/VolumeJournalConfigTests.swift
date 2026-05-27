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

@testable import ContainerAPIService

struct VolumeJournalConfigTests {

    // MARK: - Valid mode-only inputs

    @Test("Parse ordered mode without size")
    func parseOrderedModeOnly() throws {
        let config = try VolumesService.parseJournalConfig("ordered")
        #expect(config.defaultMode == .ordered)
        #expect(config.size == nil)
    }

    @Test("Parse writeback mode without size")
    func parseWritebackModeOnly() throws {
        let config = try VolumesService.parseJournalConfig("writeback")
        #expect(config.defaultMode == .writeback)
        #expect(config.size == nil)
    }

    @Test("Parse journal mode without size")
    func parseJournalModeOnly() throws {
        let config = try VolumesService.parseJournalConfig("journal")
        #expect(config.defaultMode == .journal)
        #expect(config.size == nil)
    }

    // MARK: - Valid mode:size inputs

    @Test("Parse ordered mode with mebibyte size")
    func parseOrderedWithMebibyteSize() throws {
        let config = try VolumesService.parseJournalConfig("ordered:128m")
        #expect(config.defaultMode == .ordered)
        #expect(config.size == 128 * 1024 * 1024)
    }

    @Test("Parse writeback mode with gibibyte size")
    func parseWritebackWithGibibyteSize() throws {
        let config = try VolumesService.parseJournalConfig("writeback:1g")
        #expect(config.defaultMode == .writeback)
        #expect(config.size == 1024 * 1024 * 1024)
    }

    @Test("Parse journal mode with kibibyte size")
    func parseJournalWithKibibyteSize() throws {
        let config = try VolumesService.parseJournalConfig("journal:64m")
        #expect(config.defaultMode == .journal)
        #expect(config.size == 64 * 1024 * 1024)
    }

    // MARK: - Invalid mode

    @Test("Invalid mode 'none' throws")
    func parseNoneModeThrows() {
        #expect(throws: (any Error).self) {
            _ = try VolumesService.parseJournalConfig("none")
        }
    }

    @Test("Unrecognised mode throws")
    func parseUnrecognisedModeThrows() {
        #expect(throws: (any Error).self) {
            _ = try VolumesService.parseJournalConfig("badmode")
        }
    }

    @Test("Empty string throws")
    func parseEmptyStringThrows() {
        #expect(throws: (any Error).self) {
            _ = try VolumesService.parseJournalConfig("")
        }
    }

    // MARK: - Invalid size

    @Test("Non-numeric size throws")
    func parseInvalidSizeThrows() {
        #expect(throws: (any Error).self) {
            _ = try VolumesService.parseJournalConfig("ordered:abc")
        }
    }

    @Test("Unknown size unit throws")
    func parseUnknownSizeUnitThrows() {
        #expect(throws: (any Error).self) {
            _ = try VolumesService.parseJournalConfig("ordered:128x")
        }
    }
}
