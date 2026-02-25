//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
import ContainerizationError
import Foundation

extension Application {
    public struct ContainerCommit: AsyncLoggableCommand {
        public init() {}
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "commit",
                abstract: "Create an image from a container state",
            )
        }

        @OptionGroup
        public var logOptions: Flags.Logging

        @Flag(name: .long, help: "Perform a best-effort live commit without stopping the container")
        var live = false

        @Argument(help: "container ID")
        var id: String

        @Argument(help: "image name")
        var image: String?

        public func run() async throws {
            let client = ContainerClient()
            let container = try await client.get(id: id)
            let imageName = image ?? id

            guard container.status != .stopping else {
                throw ContainerizationError(.invalidState, message: "container is stopping")
            }

            let shouldRestart = container.status == .running && !live

            if container.status == .running && live {
                let warning = "Warning: performing a best-effort live commit; the resulting filesystem may be inconsistent.\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }

            if shouldRestart {
                try await client.stop(id: id, preserveOnStop: true)
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let archive = tempDir.appendingPathComponent("archive.tar")
            var restartError: Error?

            do {
                try await client.commit(id: id, archive: archive, live: live)
            } catch {
                if shouldRestart {
                    do {
                        try await Self.restartContainer(client: client, id: id)
                    } catch {
                        restartError = error
                    }
                }

                if let restartError {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to commit container and failed to restart container \(id): \(restartError)",
                        cause: error
                    )
                }

                throw error
            }

            if shouldRestart {
                do {
                    try await Self.restartContainer(client: client, id: id)
                } catch {
                    restartError = error
                }
            }

            let process = container.configuration.initProcess
            let command = [process.executable] + process.arguments
            let commandJSON = try Self.encodedJSON(command)
            let dockerfile = """
                FROM scratch
                ADD archive.tar .
                CMD \(commandJSON)
                """
            try dockerfile.data(using: .utf8)!.write(
                to: tempDir.appendingPathComponent("Dockerfile"),
                options: .atomic
            )

            let builder = try BuildCommand.parse(["-t", imageName, tempDir.absolutePath()])
            try await builder.run()

            if let restartError {
                throw ContainerizationError(
                    .internalError,
                    message: "container committed to image \(imageName), but failed to restart container \(id)",
                    cause: restartError
                )
            }
        }

        private static func restartContainer(client: ContainerClient, id: String) async throws {
            let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
            try await process.start()
        }

        private static func encodedJSON(_ values: [String]) throws -> String {
            let data = try JSONEncoder().encode(values)
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw ContainerizationError(.internalError, message: "failed to encode command as JSON")
            }
            return encoded
        }
    }
}
