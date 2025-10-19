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
import Foundation
import TerminalProgress

extension Application {
    public struct ImageLoad: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "load",
            abstract: "Load images from an OCI compatible tar archive"
        )

        @Option(
            name: .shortAndLong, help: "Path to the image tar archive", completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        var input: String

        @OptionGroup
        var global: Flags.Global

        public func run() async throws {
            guard FileManager.default.fileExists(atPath: input) else {
                print("File does not exist \(input)")
                Application.exit(withError: ArgumentParser.ExitCode(1))
            }

            let progressConfig = try ProgressConfig(
                showTasks: true,
                showItems: true,
                totalTasks: 2
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            progress.set(description: "Loading tar archive")
            let loaded = try await ClientImage.load(from: input)

            let taskManager = ProgressTaskCoordinator()
            let unpackTask = await taskManager.startTask()
            progress.set(description: "Unpacking image")
            progress.set(itemsName: "entries")
            for image in loaded {
                try await image.unpack(platform: nil, progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progress.handler))
            }
            await taskManager.finish()
            progress.finish()
            print("Loaded images:")
            for image in loaded {
                print(image.reference)
            }
        }
    }
}
