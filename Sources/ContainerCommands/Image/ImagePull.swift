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
import ContainerPersistence
import ContainerPlugin
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

extension Application {
    public struct ImagePull: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Pull an image"
        )

        @OptionGroup
        var registry: Flags.Registry

        @OptionGroup
        var progressFlags: Flags.Progress

        @OptionGroup
        var imageFetchFlags: Flags.ImageFetch

        @Option(
            name: .shortAndLong,
            help: "Limit the pull to the specified architecture"
        )
        var arch: String?

        @Option(
            help: "Limit the pull to the specified OS"
        )
        var os: String?

        @Option(
            help: "Limit the pull to a platform (os/arch[/variant]; 'all' unpacks every platform; takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]"
        )
        var platform: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument var reference: String

        public init() {}

        public init(platform: String? = nil, scheme: String = "auto", reference: String) {
            self.logOptions = Flags.Logging()
            self.registry = Flags.Registry(scheme: scheme)
            self.platform = platform
            self.reference = reference
        }

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
            let selection = try Self.resolvePlatforms(platform: platform, os: os, arch: arch, log: log)

            let scheme = try RequestScheme(registry.scheme)

            let processedReference = try ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig)

            let progressConfig = try self.progressFlags.makeConfig(
                showTasks: true,
                showItems: true,
                ignoreSmallSize: true,
                totalTasks: 2
            )

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            progress.set(description: "Fetching image")
            progress.set(itemsName: "blobs")
            let taskManager = ProgressTaskCoordinator()
            let fetchTask = await taskManager.startTask()
            let image = try await ClientImage.pull(
                reference: processedReference, platform: selection.fetch, scheme: scheme, containerSystemConfig: containerSystemConfig,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progress.handler),
                maxConcurrentDownloads: self.imageFetchFlags.maxConcurrentDownloads
            )

            progress.set(description: "Unpacking image")
            progress.set(itemsName: "entries")
            let unpackTask = await taskManager.startTask()
            try await image.unpack(platform: selection.unpack, progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progress.handler))
            await taskManager.finish()
            progress.finish()
        }

        struct PlatformSelection {
            let fetch: ContainerizationOCI.Platform?
            let unpack: ContainerizationOCI.Platform?
        }

        /// Resolves the platforms used for fetching and unpacking.
        ///
        /// `--platform all` fetches every platform and unpacks every platform,
        /// restoring the previous behavior. Otherwise the fetch uses the
        /// requested platform (or all platforms when none is requested, so
        /// blobs remain available offline), and unpacking defaults to the host
        /// platform to avoid one snapshot per architecture.
        static func resolvePlatforms(
            platform: String?,
            os: String?,
            arch: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            log: Logger? = nil
        ) throws -> PlatformSelection {
            if platform?.lowercased() == "all" {
                guard os == nil, arch == nil else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "--platform all cannot be combined with --os or --arch"
                    )
                }
                return PlatformSelection(fetch: nil, unpack: nil)
            }
            let resolved = try DefaultPlatform.resolve(platform: platform, os: os, arch: arch, environment: environment, log: log)
            return PlatformSelection(fetch: resolved, unpack: resolved ?? .current)
        }
    }
}
