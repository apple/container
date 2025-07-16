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
import Foundation
import TerminalProgress

extension Application {
    struct ImageSave: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Save an image as an OCI compatible tar archive"
        )

        @OptionGroup
        var global: Flags.Global

        @Option(help: "Platform string in the form 'os/arch/variant'. Example 'linux/arm64/v8', 'linux/amd64'") var platform: String?

        @Option(
            name: .shortAndLong, help: "Path to save the image tar archive", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        var output: String

        @Argument var reference: String

        func run() async throws {
            var p: Platform?
            if let platform {
                p = try Platform(from: platform)
            }

            let progressConfig = try ProgressConfig(
                description: "Saving image"
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            let image = try await ClientImage.get(reference: reference)
            try await image.save(out: output, platform: p)

            progress.finish()
            print("Image saved")
        }
    }
}
