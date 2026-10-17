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
import ContainerizationOCI
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
            help: "Limit the pull to the specified platform (format: os/arch[/variant], takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]"
        )
        var platform: String?

        @Flag(
            name: .long,
            help: "Unpack all platforms (default unpacks host platform only to save disk space)"
        )
        var allPlatforms = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument var reference: String

        public init() {}

        public init(platform: String? = nil, scheme: String = "auto", reference: String, allPlatforms: Bool = false) {
            self.logOptions = Flags.Logging()
            self.registry = Flags.Registry(scheme: scheme)
            self.platform = platform
            self.reference = reference
            self.allPlatforms = allPlatforms
        }

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
            let p = try DefaultPlatform.resolve(platform: platform, os: os, arch: arch, log: log)

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
                reference: processedReference, platform: p, scheme: scheme, containerSystemConfig: containerSystemConfig,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progress.handler),
                maxConcurrentDownloads: self.imageFetchFlags.maxConcurrentDownloads
            )

            progress.set(description: "Unpacking image")
            progress.set(itemsName: "entries")
            let unpackTask = await taskManager.startTask()
            let unpackPlatform: ContainerizationOCI.Platform?
            if allPlatforms {
                unpackPlatform = p
            } else if let p {
                unpackPlatform = p
            } else {
                unpackPlatform = try ContainerizationOCI.Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
            }
            try await image.unpack(platform: unpackPlatform, progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progress.handler))
            await taskManager.finish()
            progress.finish()
        }
    }
}
