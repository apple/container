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
import ContainerizationOCI
import Crypto
import Foundation
import TerminalProgress

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

        @Flag(name: .long, help: "Commit a container while it is running")
        var live: Bool = false

        @Argument(help: "container ID")
        var id: String

        @Argument(help: "image reference for the committed image")
        var reference: String

        public func run() async throws {
            let client = ContainerClient()
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let rootfsArchive = tempDir.appendingPathComponent("rootfs.tar")
            try await client.export(id: id, archive: rootfsArchive, live: live)

            let ociLayout = tempDir.appendingPathComponent("oci-layout")
            try FileManager.default.createDirectory(at: ociLayout, withIntermediateDirectories: true)
            try Self.createOCILayout(from: rootfsArchive, at: ociLayout, reference: reference)

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
            let result = try await ClientImage.load(from: ociLayout.path(), force: false)
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

        private static func createOCILayout(from archive: URL, at directory: URL, reference: String) throws {
            let blobsDirectory =
                directory
                .appendingPathComponent("blobs")
                .appendingPathComponent("sha256")
            try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

            let layerDescriptor = try writeBlob(fromFile: archive, mediaType: MediaTypes.imageLayer, into: blobsDirectory)
            let platform = Platform.current
            let created = ISO8601DateFormatter().string(from: Date())
            let config = Image(
                created: created,
                architecture: platform.architecture,
                os: platform.os,
                variant: platform.variant,
                rootfs: Rootfs(type: "layers", diffIDs: [layerDescriptor.digest]),
                history: [History(created: created, createdBy: "container commit")]
            )
            let configDescriptor = try writeBlob(fromEncodable: config, mediaType: MediaTypes.imageConfig, into: blobsDirectory)

            let manifest = Manifest(config: configDescriptor, layers: [layerDescriptor])
            var manifestDescriptor = try writeBlob(fromEncodable: manifest, mediaType: MediaTypes.imageManifest, into: blobsDirectory)
            manifestDescriptor.annotations = [
                "org.opencontainers.image.ref.name": reference,
                "io.containerd.image.name": reference,
                "com.apple.containerization.image.name": reference,
            ]
            manifestDescriptor.platform = platform

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]

            let layoutData = try encoder.encode(["imageLayoutVersion": "1.0.0"])
            try layoutData.write(to: directory.appendingPathComponent("oci-layout"), options: .atomic)

            let index = Index(schemaVersion: 2, manifests: [manifestDescriptor])
            let indexData = try encoder.encode(index)
            try indexData.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        }

        private static func writeBlob(fromFile source: URL, mediaType: String, into blobsDirectory: URL) throws -> Descriptor {
            let data = try Data(contentsOf: source)
            return try writeBlob(data: data, mediaType: mediaType, into: blobsDirectory)
        }

        private static func writeBlob(fromEncodable value: some Encodable, mediaType: String, into blobsDirectory: URL) throws -> Descriptor {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return try writeBlob(data: data, mediaType: mediaType, into: blobsDirectory)
        }

        private static func writeBlob(data: Data, mediaType: String, into blobsDirectory: URL) throws -> Descriptor {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let digestString = "sha256:\(digest)"
            let blobURL = blobsDirectory.appendingPathComponent(digest)
            try data.write(to: blobURL, options: .atomic)
            return Descriptor(mediaType: mediaType, digest: digestString, size: Int64(data.count))
        }
    }
}
