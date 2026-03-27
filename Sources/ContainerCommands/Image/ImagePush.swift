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
import ContainerizationOCI
import Foundation
import TerminalProgress

extension Application {
    public struct ImagePush: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "push",
            abstract: "Push an image"
        )

        @OptionGroup
        var registry: Flags.Registry

        @OptionGroup
        var progressFlags: Flags.Progress

        @OptionGroup
        var imageUploadFlags: Flags.ImageUpload

        @Option(
            name: .shortAndLong,
            help: "Limit the push to the specified architecture"
        )
        var arch: String?

        @Option(
            help: "Limit the push to the specified OS"
        )
        var os: String?

        @Option(help: "Limit the push to the specified platform (format: os/arch[/variant], takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]")
        var platform: String?

        @Flag(name: .long, help: "Push all tags of an image")
        var allTags: Bool = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument var reference: String

        public init() {}

        public func validate() throws {
            if allTags {
                let ref = try Reference.parse(reference)
                if ref.tag != nil {
                    throw ContainerizationError(.invalidArgument, message: "tag can't be used with --all-tags")
                }
                if ref.digest != nil {
                    throw ContainerizationError(.invalidArgument, message: "digest can't be used with --all-tags")
                }
            }
        }

        public func run() async throws {
            let p = try DefaultPlatform.resolve(platform: platform, os: os, arch: arch, log: log)
            let scheme = try RequestScheme(registry.scheme)

            if allTags {
                try await pushAllTags(platform: p, scheme: scheme)
            } else {
                try await pushSingle(platform: p, scheme: scheme)
            }
        }

        private func pushSingle(platform: Platform?, scheme: RequestScheme) async throws {
            let image = try await ClientImage.get(reference: reference)

            var progressConfig: ProgressConfig
            switch self.progressFlags.progress {
            case .none: progressConfig = try ProgressConfig(disableProgressUpdates: true)
            case .ansi:
                progressConfig = try ProgressConfig(
                    description: "Pushing image \(image.reference)",
                    itemsName: "blobs",
                    showItems: true,
                    showSpeed: false,
                    ignoreSmallSize: true
                )
            }

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            try await image.push(platform: platform, scheme: scheme, progressUpdate: progress.handler)
            progress.finish()
        }

        private func pushAllTags(platform: Platform?, scheme: RequestScheme) async throws {
            if self.platform != nil || arch != nil || os != nil {
                log.warning("--platform/--arch/--os with --all-tags filters each tag push to the specified platform; tags without matching manifests may fail")
            }

            let normalized = try ClientImage.normalizeReference(reference)
            let displayRepo = try ClientImage.denormalizeReference(normalized)
            let displayName = try Reference.parse(displayRepo).name
            print("The push refers to repository [\(displayName)]")

            var progressConfig: ProgressConfig
            switch self.progressFlags.progress {
            case .none: progressConfig = try ProgressConfig(disableProgressUpdates: true)
            case .ansi:
                progressConfig = try ProgressConfig(
                    description: "Pushing tags",
                    showPercent: false,
                    showItems: false,
                    showSpeed: false,
                    ignoreSmallSize: true
                )
            }

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            let pushed = try await ClientImage.pushAllTags(
                reference: reference, platform: platform, scheme: scheme,
                maxConcurrentUploads: imageUploadFlags.maxConcurrentUploads, progressUpdate: progress.handler)
            progress.finish()

            let formatter = ByteCountFormatter()
            for img in pushed {
                let tag = (try? Reference.parse(img.reference))?.tag ?? "<none>"
                let size = formatter.string(fromByteCount: img.descriptor.size)
                print("\(tag): digest: \(img.descriptor.digest) size: \(size)")
            }
        }
    }
}
