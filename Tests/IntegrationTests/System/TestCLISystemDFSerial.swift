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

/// Tests for `container system df`. All tests clear and inspect the global image
/// store, so they must run serially with no concurrent image activity.
@Suite(.serialized)
struct TestCLISystemDFSerial {
    private struct DiskUsageStats: Decodable {
        let images: ResourceUsage
    }
    private struct ResourceUsage: Decodable {
        let active: Int
        let reclaimable: UInt64
        let sizeInBytes: UInt64
        let total: Int
    }

    private let alpine = ContainerFixture.warmupImages[0]

    // Issue #1526: reported image size must include content blobs, not just unpacked snapshots.
    @Test func imageDiskUsageIsPopulatedAfterPull() async throws {
        try await ContainerFixture.with { f in
            try withCleanImageStore(f) {
                try f.doPull(self.alpine)
                let stats = try systemDiskUsage(f)
                #expect(stats.images.total >= 1)
                #expect(stats.images.active == 0)
                #expect(stats.images.sizeInBytes > 0)
                #expect(stats.images.reclaimable == stats.images.sizeInBytes)
            }
        }
    }

    // Issue #1527: tagging the same image must not double-count its storage.
    @Test func tagsDoNotDoubleCountImageStorage() async throws {
        try await ContainerFixture.with { f in
            try withCleanImageStore(f) {
                try f.doPull(self.alpine)
                let before = try systemDiskUsage(f)
                try f.doImageTag(self.alpine, newName: "local/system-df-alpine:tag-one")
                try f.doImageTag(self.alpine, newName: "local/system-df-alpine:tag-two")
                let after = try systemDiskUsage(f)
                #expect(after.images.total == before.images.total + 2)
                #expect(after.images.sizeInBytes == before.images.sizeInBytes)
                #expect(after.images.reclaimable == before.images.reclaimable)
            }
        }
    }

    // Issue #1527: removing one of several tags must not free shared storage.
    @Test func deletingOneOfMultipleTagsPreservesSharedStorage() async throws {
        try await ContainerFixture.with { f in
            try withCleanImageStore(f) {
                let baseline = try systemDiskUsage(f)
                try f.doPull(self.alpine)
                try f.doImageTag(self.alpine, newName: "local/system-df-alpine:delete-probe")
                let beforeDelete = try systemDiskUsage(f)

                try f.doRemoveImages(["local/system-df-alpine:delete-probe"])
                let afterAliasDelete = try systemDiskUsage(f)
                #expect(afterAliasDelete.images.total == beforeDelete.images.total - 1)
                #expect(afterAliasDelete.images.sizeInBytes == beforeDelete.images.sizeInBytes)
                #expect(afterAliasDelete.images.reclaimable == beforeDelete.images.reclaimable)

                _ = try? f.doRemoveImages()
                let afterFullClean = try systemDiskUsage(f)
                #expect(afterFullClean.images.total <= baseline.images.total)
                #expect(afterFullClean.images.sizeInBytes <= baseline.images.sizeInBytes)
            }
        }
    }

    // MARK: - Private helpers

    private func withCleanImageStore(_ f: ContainerFixture, _ body: () throws -> Void) throws {
        _ = try? f.doRemoveImages()
        defer { _ = try? f.doRemoveImages() }
        try body()
    }

    private func systemDiskUsage(_ f: ContainerFixture) throws -> DiskUsageStats {
        let result = try f.run(["system", "df", "--format", "json"]).check()
        return try JSONDecoder().decode(DiskUsageStats.self, from: result.outputData)
    }
}
