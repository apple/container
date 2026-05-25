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

import Foundation
import Testing

@testable import ContainerImagesService

struct DockerArchiveConverterTests {
    @Test func convertsDockerArchiveToOciLayout() throws {
        let directory = try Self.makeDockerArchive(repoTags: ["example.com/test/image:latest"])
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try DockerArchiveConverter.convertIfNeeded(at: directory)

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("oci-layout").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))

        let index = try Self.readJSON(Index.self, from: directory.appendingPathComponent("index.json"))
        #expect(index.schemaVersion == 2)
        #expect(index.mediaType == "application/vnd.oci.image.index.v1+json")
        #expect(index.manifests.count == 1)
        #expect(index.manifests[0].mediaType == "application/vnd.oci.image.manifest.v1+json")
        #expect(index.manifests[0].annotations?["org.opencontainers.image.ref.name"] == "example.com/test/image:latest")
        #expect(index.manifests[0].platform?.os == "linux")
        #expect(index.manifests[0].platform?.architecture == "arm64")

        let manifest = try Self.readBlob(Manifest.self, digest: index.manifests[0].digest, from: directory)
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.config.mediaType == "application/vnd.oci.image.config.v1+json")
        #expect(manifest.layers.count == 1)
        #expect(manifest.layers[0].mediaType == "application/vnd.oci.image.layer.v1.tar")
        #expect(FileManager.default.fileExists(atPath: Self.blobPath(manifest.config.digest, in: directory).path))
        #expect(FileManager.default.fileExists(atPath: Self.blobPath(manifest.layers[0].digest, in: directory).path))
    }

    @Test func createsOneIndexDescriptorPerRepoTag() throws {
        let directory = try Self.makeDockerArchive(repoTags: ["example.com/test/image:one", "example.com/test/image:two"])
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try DockerArchiveConverter.convertIfNeeded(at: directory)

        let index = try Self.readJSON(Index.self, from: directory.appendingPathComponent("index.json"))
        #expect(index.manifests.count == 2)
        #expect(index.manifests[0].digest == index.manifests[1].digest)
        #expect(Set(index.manifests.compactMap { $0.annotations?["org.opencontainers.image.ref.name"] }) == ["example.com/test/image:one", "example.com/test/image:two"])
    }

    @Test func rejectsDockerArchiveConfigPathEscapingImageDirectory() throws {
        let directory = try Self.makeDockerArchive(repoTags: ["example.com/test/image:latest"], config: "../config.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        #expect {
            try DockerArchiveConverter.convertIfNeeded(at: directory)
        } throws: { error in
            String(describing: error).contains("docker archive member escapes image directory: ../config.json")
        }
    }

    @Test func leavesExistingOciLayoutUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let existingLayout = Data(#"{"imageLayoutVersion":"1.0.0","extra":"kept"}"#.utf8)
        try existingLayout.write(to: directory.appendingPathComponent("oci-layout"))
        try Data("not docker".utf8).write(to: directory.appendingPathComponent("manifest.json"))

        try DockerArchiveConverter.convertIfNeeded(at: directory)

        #expect(try Data(contentsOf: directory.appendingPathComponent("oci-layout")) == existingLayout)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
    }

    @Test func ignoresDirectoriesWithoutRecognizedLayout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try DockerArchiveConverter.convertIfNeeded(at: directory)

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("oci-layout").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
    }

    private static func makeDockerArchive(repoTags: [String], config configPath: String = "config.json") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config = Data(#"{"architecture":"arm64","config":{},"os":"linux","rootfs":{"diff_ids":[],"type":"layers"}}"#.utf8)
        try config.write(to: directory.appendingPathComponent("config.json"))

        let layerDirectory = directory.appendingPathComponent("layer", isDirectory: true)
        try FileManager.default.createDirectory(at: layerDirectory, withIntermediateDirectories: true)
        try Data("layer contents".utf8).write(to: layerDirectory.appendingPathComponent("layer.tar"))

        let manifest = DockerManifestFixture(config: configPath, repoTags: repoTags, layers: ["layer/layer.tar"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode([manifest]).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private static func readBlob<T: Decodable>(_ type: T.Type, digest: String, from directory: URL) throws -> T {
        try Self.readJSON(type, from: Self.blobPath(digest, in: directory))
    }

    private static func blobPath(_ digest: String, in directory: URL) -> URL {
        let digestValue = digest.replacingOccurrences(of: "sha256:", with: "")
        return directory.appendingPathComponent("blobs/sha256/\(digestValue)")
    }
}

private struct DockerManifestFixture: Encodable {
    let config: String
    let repoTags: [String]
    let layers: [String]

    enum CodingKeys: String, CodingKey {
        case config = "Config"
        case repoTags = "RepoTags"
        case layers = "Layers"
    }
}

private struct Index: Decodable {
    let schemaVersion: Int
    let mediaType: String
    let manifests: [Descriptor]
}

private struct Manifest: Decodable {
    let schemaVersion: Int
    let config: Descriptor
    let layers: [Descriptor]
}

private struct Descriptor: Decodable {
    let mediaType: String
    let digest: String
    let size: Int
    let annotations: [String: String]?
    let platform: Platform?
}

private struct Platform: Decodable {
    let architecture: String
    let os: String
}
