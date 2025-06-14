//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import Containerization
import ContainerizationOCI
import TerminalProgress

extension Application {
    struct ImagePush: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "push",
            abstract: "Push an image"
        )

        @OptionGroup
        var global: Flags.Global

        @OptionGroup
        var registry: Flags.Registry

        @OptionGroup
        var progressFlags: Flags.Progress

        @Option(help: "Platform string in the form 'os/arch/variant'. Example 'linux/arm64/v8', 'linux/amd64'") var platform: String?

        @Argument var reference: String

        func run() async throws {
            var p: Platform?
            if let platform {
                p = try Platform(from: platform)
            }

            let scheme = try RequestScheme(registry.scheme)
            let image = try await ClientImage.get(reference: reference)

            var progressConfig: ProgressConfig
            if progressFlags.disableProgressUpdates {
                progressConfig = try ProgressConfig(disableProgressUpdates: progressFlags.disableProgressUpdates)
            } else {
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
            _ = try await image.push(platform: p, scheme: scheme, progressUpdate: progress.handler)
            progress.finish()
        }
    }
}
