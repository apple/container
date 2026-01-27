//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerizationOCI
import Foundation

extension Application {
    public struct ImagePrune: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove all dangling images. If -a is specified, also remove all images not referenced by any container.")

        @OptionGroup
        public var logOptions: Flags.Logging

        @Flag(name: .shortAndLong, help: "Remove all unused images, not just dangling ones")
        var all: Bool = false

        public func run() async throws {
            let allImages = try await ClientImage.list()

            let imagesToPrune: [ClientImage]
            if all {
                // Find all images not used by any container
                let containers = try await ClientContainer.list()
                var imagesInUse = Set<String>()
                for container in containers {
                    imagesInUse.insert(container.configuration.image.reference)
                }
                imagesToPrune = allImages.filter { image in
                    !imagesInUse.contains(image.reference)
                }
            } else {
                // Find dangling images (images with no tag)
                imagesToPrune = allImages.filter { image in
                    !hasTag(image.reference)
                }
            }

            var prunedImages = [String]()

            for image in imagesToPrune {
                do {
                    try await ClientImage.delete(reference: image.reference, garbageCollect: false)
                    prunedImages.append(image.reference)
                } catch {
                    log.error("Failed to prune image \(image.reference): \(error)")
                }
            }

            let (deletedDigests, size) = try await ClientImage.cleanupOrphanedBlobs()

            for image in imagesToPrune {
                print("untagged \(image.reference)")
            }
            for digest in deletedDigests {
                print("deleted \(digest)")
            }

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let freed = formatter.string(fromByteCount: Int64(size))
            print("Reclaimed \(freed) in disk space")
        }

        private func hasTag(_ reference: String) -> Bool {
            do {
                let ref = try ContainerizationOCI.Reference.parse(reference)
                return ref.tag != nil && !ref.tag!.isEmpty
            } catch {
                return false
            }
        }
    }
}
