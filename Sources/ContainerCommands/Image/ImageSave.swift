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
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress

extension Application {
    public struct ImageSave: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Save an image as an OCI compatible tar archive"
        )

        @Option(
            name: [.customLong("arch"), .customShort("a")],
            help: "Architecture for the saved image"
        )
        var arch: String?

        @Option(
            help: "OS for the saved image"
        )
        var os: String?

        @Option(
            name: .shortAndLong, help: "Pathname for the saved image", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        var output: String

        @Option(
            help: "Platform for the saved image (format: os/arch[/variant], takes precedence over --os and --arch)"
        )
        var platform: String?

        @OptionGroup
        var global: Flags.Global

        @Argument var references: [String]

        public func run() async throws {
            var p: Platform?
            if let platform {
                p = try Platform(from: platform)
            } else if let arch {
                p = try Platform(from: "\(os ?? "linux")/\(arch)")
            } else if let os {
                p = try Platform(from: "\(os)/\(arch ?? Arch.hostArchitecture().rawValue)")
            }

            let progressConfig = try ProgressConfig(
                description: "Saving image(s)"
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            var images: [ImageDescription] = []
            for reference in references {
                do {
                    images.append(try await ClientImage.get(reference: reference).description)
                } catch {
                    print("failed to get image for reference \(reference): \(error)")
                }
            }

            guard images.count == references.count else {
                throw ContainerizationError(.invalidArgument, message: "failed to save image(s)")

            }
            try await ClientImage.save(references: references, out: output, platform: p)

            progress.finish()
            for reference in references {
                print(reference)
            }
        }
    }
}
