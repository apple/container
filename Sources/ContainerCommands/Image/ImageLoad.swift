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
import ContainerizationOS
import Foundation
import SystemPackage
import TerminalProgress

extension Application {
    public struct ImageLoad: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "load",
            abstract: "Load images from an OCI compatible tar archive"
        )

        @Option(
            name: .shortAndLong, help: "Path to the image tar archive", completion: .file(),
            transform: { str in
                FilePathOps.absolutePath(FilePath(str))
            })
        var input: FilePath?

        @Flag(name: .shortAndLong, help: "Load images even if the archive contains invalid files")
        public var force = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")
            defer {
                try? FileManager.default.removeItem(at: tempFile)
            }

            // Stage inputs that cannot be reopened by the image service process.
            let resolvedPath: FilePath
            if let input {
                guard FileManager.default.fileExists(atPath: input.string) else {
                    log.error("file does not exist", metadata: ["path": "\(input)"])
                    Application.exit(withError: ArgumentParser.ExitCode(1))
                }
                if try Self.shouldStageInput(input) {
                    let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: input.string))
                    defer {
                        try? fileHandle.close()
                    }
                    try Self.copyArchive(from: fileHandle, to: tempFile)
                    resolvedPath = FilePath(tempFile.path())
                } else {
                    resolvedPath = input
                }
            } else {
                try Self.copyArchive(from: .standardInput, to: tempFile)
                resolvedPath = FilePath(tempFile.path())
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
                from: resolvedPath.string,
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
            for image in result.images {
                print(image.reference)
            }
        }

        static func shouldStageInput(_ input: FilePath) throws -> Bool {
            if input.string.hasPrefix("/dev/fd/") || input.string == "/dev/stdin" {
                return true
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: input.string)
            return attributes[.type] as? FileAttributeType != .typeRegular
        }

        static func copyArchive(from input: FileHandle, to outputURL: URL) throws {
            guard FileManager.default.createFile(atPath: outputURL.path(), contents: nil) else {
                throw ContainerizationError(.internalError, message: "unable to create temporary file")
            }

            guard let output = try? FileHandle(forWritingTo: outputURL) else {
                throw ContainerizationError(.internalError, message: "unable to open temporary file for writing")
            }
            defer {
                try? output.close()
            }

            let bufferSize = 1024 * 1024
            while true {
                let chunk = input.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                output.write(chunk)
            }
        }
    }
}
