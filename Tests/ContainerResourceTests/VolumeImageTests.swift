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

import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import ContainerAPIService

struct VolumeImageTests {

    private func makeTempImagePath() -> FilePath {
        FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false))
    }

    @Test("formatVolumeImage produces an EXT4 image without lost+found")
    func formatVolumeImageHasNoLostAndFound() throws {
        let imagePath = makeTempImagePath()
        defer { try? FileManager.default.removeItem(at: imagePath.url) }

        try VolumesService.formatVolumeImage(at: imagePath)

        let reader = try EXT4.EXT4Reader(blockDevice: imagePath)
        let rootEntries = try reader.listDirectory(FilePath("/"))
        #expect(!rootEntries.contains("lost+found"))
    }

    @Test("Default EXT4 formatter creates lost+found (baseline)")
    func defaultFormatterCreatesLostAndFound() throws {
        let imagePath = makeTempImagePath()
        defer { try? FileManager.default.removeItem(at: imagePath.url) }

        let formatter = try EXT4.Formatter(imagePath)
        try formatter.close()

        let reader = try EXT4.EXT4Reader(blockDevice: imagePath)
        let rootEntries = try reader.listDirectory(FilePath("/"))
        #expect(rootEntries.contains("lost+found"))
    }
}
