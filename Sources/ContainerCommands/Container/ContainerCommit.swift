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
import Foundation
import SystemPackage

extension Application {
    public struct ContainerCommit: AsyncLoggableCommand {
        public init() {}
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "commit",
                abstract: "Create a new image from a container's filesystem",
            )
        }

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "container ID")
        var id: String

        @Argument(help: "image reference for the committed image")
        var reference: String

        public func run() async throws {
            let client = ContainerClient()
            let containerSystemConfig = try await Application.loadContainerSystemConfig()
            let normalizedReference = try ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig)
            let snapshot = try await client.get(id: id)
            let platform = snapshot.configuration.platform
            let sourceImage = try await ClientImage(description: snapshot.configuration.image).config(for: platform)
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let rootfsArchive = tempDir.appendingPathComponent("rootfs.tar")
            try await client.export(id: id, archive: rootfsArchive)

            let imageArchive = try OCIImageArchive.create(
                from: rootfsArchive,
                in: tempDir,
                reference: normalizedReference,
                container: snapshot,
                sourceImage: sourceImage
            )

            try await ImageLoad.load(from: FilePath(imageArchive.path()), log: log)
        }
    }
}
