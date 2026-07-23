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

import ContainerTestSupport
import Foundation
import Testing

// Reads the ext4 root filesystem's on-disk superblock directly via dd/od,
// since the standard warmup images don't ship e2fsprogs (no dumpe2fs) and
// /proc/mounts doesn't expose the ext4 "data=" journal mode at all.
//
// Superblock layout (ext4(5)): the superblock starts at byte offset 1024 on
// the device. s_feature_compat is a little-endian u32 at superblock+92; bit
// 0x4 (EXT4_FEATURE_COMPAT_HAS_JOURNAL) indicates a journal exists. Only the
// journal bit's own byte (offset 92, the field's low byte) is read since the
// bit fits there. s_default_mount_opts is a little-endian u32 at
// superblock+256; bits 0x60 select data=journal/ordered/writeback, and again
// only the low byte (offset 256) is needed. Absolute device offsets are
// therefore 1024+92=1116 and 1024+256=1280.
@Suite
struct TestCLIRunFilesystem {
    private let alpine = WarmupImage.alpine320

    private static let featureCompatOffset = 1116
    private static let defaultMountOptsOffset = 1280
    private static let hasJournalBit = 0x4
    private static let dataOrderedBits = 0x40

    @Test func testRootFilesystemHasOrderedJournal() async throws {
        try await ContainerFixture.with { f in
            let image = alpine.rawValue
            let c = "\(f.testID)-c"
            try await f.doLongRun(name: c, image: image, autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let device = try f.doExec(c, cmd: ["sh", "-c", "mount | awk '$3 == \"/\" {print $1}'"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(!device.isEmpty, "could not determine the root filesystem's backing device")

            let featureCompat = try readSuperblockByte(f, c, device, Self.featureCompatOffset)
            #expect(
                featureCompat & Self.hasJournalBit != 0,
                "expected EXT4_FEATURE_COMPAT_HAS_JOURNAL set on the root filesystem superblock, got byte \(featureCompat)")

            let defaultMountOpts = try readSuperblockByte(f, c, device, Self.defaultMountOptsOffset)
            #expect(
                defaultMountOpts & Self.dataOrderedBits == Self.dataOrderedBits,
                "expected data=ordered default mount option on the root filesystem, got byte \(defaultMountOpts)")
        }
    }

    private func readSuperblockByte(_ f: ContainerFixture, _ container: String, _ device: String, _ offset: Int) throws -> Int {
        let output = try f.doExec(container, cmd: ["sh", "-c", "dd if=\(device) bs=1 skip=\(offset) count=1 2>/dev/null | od -An -tu1"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int(trimmed), "unexpected od output reading offset \(offset) of \(device): \(output)")
    }
}
