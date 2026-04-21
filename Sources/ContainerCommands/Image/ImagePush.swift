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
import ContainerizationOCI
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

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument var reference: String

        public init() {}

        public func run() async throws {
            let p = try DefaultPlatform.resolve(platform: platform, os: os, arch: arch, log: log)

            let scheme = try RequestScheme(registry.scheme)
            let image = try await ClientImage.get(reference: reference)

            let progressConfig = try self.progressFlags.makeConfig(
                description: "Pushing image \(image.reference)",
                itemsName: "blobs",
                showItems: true,
                showSpeed: false,
                ignoreSmallSize: true
            )

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            _ = try await image.push(platform: p, scheme: scheme, progressUpdate: progress.handler)
            progress.finish()
        }
    }
}
