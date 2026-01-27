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
import Containerization
import ContainerizationError
import Foundation
import Logging

extension Application {
    public struct RemoveImageOptions: ParsableArguments {
        public init() {}

        @Flag(name: .shortAndLong, help: "Delete all images")
        var all: Bool = false

        @Flag(name: .shortAndLong, help: "Ignore errors for images that are not found")
        var force: Bool = false

        @Argument
        var images: [String] = []
    }

    struct DeleteImageImplementation {
        static func validate(options: RemoveImageOptions) throws {
            if options.images.count == 0 && !options.all {
                throw ContainerizationError(.invalidArgument, message: "no images specified and --all not supplied")
            }
            if options.images.count > 0 && options.all {
                throw ContainerizationError(.invalidArgument, message: "explicitly supplied images conflict with the --all flag")
            }
        }

        static func removeImage(options: RemoveImageOptions, log: Logger) async throws {
            let (found, notFound) = try await {
                if options.all {
                    let found = try await ClientImage.list()
                    let notFound: [String] = []
                    return (found, notFound)
                }
                return try await ClientImage.get(names: options.images)
            }()
            var failures: [String] = options.force ? [] : notFound
            var didDeleteAnyImage = false
            for image in found {
                guard !Utility.isInfraImage(name: image.reference) else {
                    continue
                }
                do {
                    try await ClientImage.delete(reference: image.reference, garbageCollect: false)
                    print(image.reference)
                    didDeleteAnyImage = true
                } catch {
                    log.error("failed to delete \(image.reference): \(error)")
                    failures.append(image.reference)
                }
            }
            let (_, size) = try await ClientImage.cleanupOrphanedBlobs()
            let formatter = ByteCountFormatter()
            let freed = formatter.string(fromByteCount: Int64(size))

            if didDeleteAnyImage {
                print("Reclaimed \(freed) in disk space")
            }
            if failures.count > 0 {
                throw ContainerizationError(.internalError, message: "failed to delete one or more images: \(failures)")
            }
        }
    }

    public struct ImageDelete: AsyncLoggableCommand {
        @OptionGroup
        var options: RemoveImageOptions

        @OptionGroup
        public var logOptions: Flags.Logging

        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one or more images",
            aliases: ["rm"])

        public init() {}

        public func validate() throws {
            try DeleteImageImplementation.validate(options: options)
        }

        public mutating func run() async throws {
            try await DeleteImageImplementation.removeImage(options: options, log: log)
        }
    }
}
