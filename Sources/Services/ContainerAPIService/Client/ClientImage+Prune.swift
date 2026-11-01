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

import ContainerizationOCI

extension ClientImage {
    /// Remove unused images, returning the outcome of the operation.
    ///
    /// When `all` is `true`, every image not referenced by a container is removed;
    /// otherwise only dangling (untagged) images are removed. Orphaned blobs are
    /// garbage collected afterwards and reported via ``PruneResult/deletedDigests``.
    public static func prune(all: Bool) async throws -> PruneResult {
        let allImages = try await list()

        let imagesToPrune: [ClientImage]
        if all {
            // Find all images not used by any container.
            let client = ContainerClient()
            let containers = try await client.list()
            var imagesInUse = Set<String>()
            for container in containers {
                imagesInUse.insert(container.configuration.image.reference)
            }
            imagesToPrune = allImages.filter { image in
                !imagesInUse.contains(image.reference)
            }
        } else {
            // Find dangling images (images with no tag).
            imagesToPrune = allImages.filter { image in
                !hasTag(image.reference)
            }
        }

        var prunedImages = [String]()
        var failed = [PruneResult.Failure]()

        for image in imagesToPrune {
            do {
                try await delete(reference: image.reference, garbageCollect: false)
                prunedImages.append(image.reference)
            } catch {
                failed.append(PruneResult.Failure(id: image.reference, error: error))
            }
        }

        let (deletedDigests, size) = try await cleanUpOrphanedBlobs()

        return PruneResult(
            pruned: prunedImages,
            failed: failed,
            reclaimedBytes: size,
            deletedDigests: deletedDigests
        )
    }

    private static func hasTag(_ reference: String) -> Bool {
        do {
            let ref = try ContainerizationOCI.Reference.parse(reference)
            return ref.tag != nil && !ref.tag!.isEmpty
        } catch {
            return false
        }
    }
}
