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
        var input: String?

        @Flag(name: .shortAndLong, help: "Load images even if the archive contains invalid files")
        public var force = false

        @OptionGroup
        var global: Flags.Global

        public func run() async throws {
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")
            defer {
                try? FileManager.default.removeItem(at: tempFile)
            }

            // Read from stdin; otherwise read from the input file
            if input == nil {
                guard FileManager.default.createFile(atPath: tempFile.path(), contents: nil) else {
                    throw ContainerizationError(.internalError, message: "unable to create temporary file")
                }

                guard let fileHandle = try? FileHandle(forWritingTo: tempFile) else {
                    throw ContainerizationError(.internalError, message: "unable to open temporary file for writing")
                }

                let bufferSize = 4096
                while true {
                    let chunk = FileHandle.standardInput.readData(ofLength: bufferSize)
                    if chunk.isEmpty { break }
                    fileHandle.write(chunk)
                }
                try fileHandle.close()
            } else {
                guard FileManager.default.fileExists(atPath: input!) else {
                    print("File does not exist \(input!)")
                    Application.exit(withError: ArgumentParser.ExitCode(1))
                }
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
            let result = try await ClientImage.load(
                from: input ?? tempFile.path(),
                force: force)
            if !result.rejectedMembers.isEmpty {
                log.warning("archive contains invalid members", metadata: ["paths": "\(result.rejectedMembers)"])
            }

            let taskManager = ProgressTaskCoordinator()
            let unpackTask = await taskManager.startTask()
            progress.set(description: "Unpacking image")
            progress.set(itemsName: "entries")
            for image in result.images {
                try await image.unpack(platform: nil, progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progress.handler))
            }
            await taskManager.finish()
            progress.finish()
            print("Loaded images:")
            for image in result.images {
                print(image.reference)
            }
        }
    }
}
