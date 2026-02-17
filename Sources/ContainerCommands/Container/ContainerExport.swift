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
import TerminalProgress

extension Application {
    public struct ContainerExport: AsyncLoggableCommand {
        public init() {}
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "export",
                abstract: "Export a container state to an image",
            )
        }

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "image name")
        var image: String?

        @Argument(help: "container ID")
        var id: String

        public func run() async throws {
            let client = ContainerClient()
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let imageName = image ?? id

            let archive = tempDir.appendingPathComponent("archive.tar")
            try await client.export(id: id, archive: archive)

            let dockerfile = """
                FROM scratch
                ADD archive.tar .
                """
            try dockerfile.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("Dockerfile"), options: .atomic)

            let builder = try BuildCommand.parse(["-t", imageName, tempDir.absolutePath()])

            try await builder.run()
        }
    }
}
