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

@Suite(.serialSuites, .serialized)
final class TestCLISystemDF: CLITest {
    private struct DiskUsageStats: Decodable {
        let images: ResourceUsage
    }

    private struct ResourceUsage: Decodable {
        let active: Int
        let reclaimable: UInt64
        let sizeInBytes: UInt64
        let total: Int
    }

    // Issue #1526: reported image size must include content blobs, not just unpacked snapshots.
    @Test func imageDiskUsageIsPopulatedAfterPull() throws {
        try withCleanImageStore {
            try doPull(imageName: alpine)
            let stats = try systemDiskUsage()
            #expect(stats.images.total >= 1)
            #expect(stats.images.active == 0)
            #expect(stats.images.sizeInBytes > 0)
            #expect(stats.images.reclaimable == stats.images.sizeInBytes)
        }
    }

    // Issue #1527: tagging the same image must not double-count its storage.
    @Test func tagsDoNotDoubleCountImageStorage() throws {
        try withCleanImageStore {
            try doPull(imageName: alpine)
            let before = try systemDiskUsage()

            try doImageTag(image: alpine, newName: "local/system-df-alpine:tag-one")
            try doImageTag(image: alpine, newName: "local/system-df-alpine:tag-two")
            let after = try systemDiskUsage()

            #expect(after.images.total == before.images.total + 2)
            #expect(after.images.sizeInBytes == before.images.sizeInBytes)
            #expect(after.images.reclaimable == before.images.reclaimable)
        }
    }

    // Issue #1527: removing one of several tags must not free shared storage.
    // Assumes no background GC runs between operations; blobs stay until all references are removed.
    @Test func deletingOneOfMultipleTagsPreservesSharedStorage() throws {
        try withCleanImageStore {
            let baseline = try systemDiskUsage()

            try doPull(imageName: alpine)
            try doImageTag(image: alpine, newName: "local/system-df-alpine:delete-probe")
            let beforeDelete = try systemDiskUsage()

            try doRemoveImages(images: ["local/system-df-alpine:delete-probe"])
            let afterAliasDelete = try systemDiskUsage()

            #expect(afterAliasDelete.images.total == beforeDelete.images.total - 1)
            #expect(afterAliasDelete.images.sizeInBytes == beforeDelete.images.sizeInBytes)
            #expect(afterAliasDelete.images.reclaimable == beforeDelete.images.reclaimable)

            _ = try? run(arguments: ["image", "rm", "--all"])
            let afterFullClean = try systemDiskUsage()
            #expect(afterFullClean.images.total <= baseline.images.total)
            #expect(afterFullClean.images.sizeInBytes <= baseline.images.sizeInBytes)
        }
    }

    private func withCleanImageStore(_ body: () throws -> Void) throws {
        _ = try? run(arguments: ["image", "rm", "--all"])
        defer {
            _ = try? run(arguments: ["image", "rm", "--all"])
        }
        try body()
    }

    private func systemDiskUsage() throws -> DiskUsageStats {
        let (data, _, error, status) = try run(arguments: ["system", "df", "--format", "json"])
        guard status == 0 else {
            throw CLIError.executionFailed("system df failed: \(error)")
        }
        return try JSONDecoder().decode(DiskUsageStats.self, from: data)
    }
}
