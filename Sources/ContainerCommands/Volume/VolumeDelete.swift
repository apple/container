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

import ArgumentParser
import ContainerClient
import ContainerizationError
import Foundation

extension Application.VolumeCommand {
    public struct VolumeDelete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one or more volumes",
            aliases: ["rm"]
        )

        @Flag(name: .shortAndLong, help: "Delete all volumes")
        var all = false

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Volume names")
        var names: [String] = []

        public init() {}

        public func run() async throws {
            let volumes: [Volume]

            if all {
                volumes = try await ClientVolume.list()
            } else {
                volumes = try await ClientVolume.search(searches: names)

                // If one of the search terms requested has no volumes present, let's throw. We don't need to do
                // this for --all as --all should be perfectly usable with no volumes to remove,
                // otherwise it'd be quite clunky.
                var missingTerms: [String] = []

                for searchTerm in names {
                    if StringMatcher.match(partial: searchTerm, candidates: volumes.map({ $0.id })) == .noMatch {
                        missingTerms.append(searchTerm)
                    }
                }

                if missingTerms.count > 0 {
                    throw ContainerizationError(
                        .notFound,
                        message: "failed to delete one or more volumes: \(missingTerms)"
                    )
                }
            }

            var failed = [String]()
            try await withThrowingTaskGroup(of: Volume?.self) { group in
                for volume in volumes {
                    group.addTask {
                        do {
                            try await ClientVolume.delete(name: volume.id)
                            print(volume.id)
                            return nil
                        } catch {
                            log.error("failed to delete volume \(volume.id): \(error)")
                            return volume
                        }
                    }
                }

                for try await volume in group {
                    guard let volume else {
                        continue
                    }
                    failed.append(volume.id)
                }
            }

            if failed.count > 0 {
                throw ContainerizationError(.internalError, message: "delete failed for one or more volumes: \(failed)")
            }
        }
    }
}
