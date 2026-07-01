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

import ContainerizationError
import CryptoKit
import Foundation

struct DockerArchiveConverter {
    static let ociLayoutFile = "oci-layout"
    static let dockerManifestFile = "manifest.json"

    private static let ociLayoutMediaType = "application/vnd.oci.image.index.v1+json"
    private static let ociManifestMediaType = "application/vnd.oci.image.manifest.v1+json"
    private static let ociConfigMediaType = "application/vnd.oci.image.config.v1+json"
    private static let ociLayerMediaType = "application/vnd.oci.image.layer.v1.tar"
    private static let ociGzipLayerMediaType = "application/vnd.oci.image.layer.v1.tar+gzip"
    private static let refNameAnnotation = "org.opencontainers.image.ref.name"

    static func convertIfNeeded(at directory: URL) throws {
        let ociLayoutPath = directory.appendingPathComponent(Self.ociLayoutFile).path
        if FileManager.default.fileExists(atPath: ociLayoutPath) {
            return
        }

        let dockerManifestURL = directory.appendingPathComponent(Self.dockerManifestFile)
        if FileManager.default.fileExists(atPath: dockerManifestURL.path) {
            try Self.convert(at: directory, dockerManifestURL: dockerManifestURL)
        }
    }

    private static func convert(at directory: URL, dockerManifestURL: URL) throws {
        let decoder = JSONDecoder()
        let archiveManifest = try decoder.decode([DockerManifestEntry].self, from: Data(contentsOf: dockerManifestURL))
        let blobsDirectory = directory.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent("sha256", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        var indexDescriptors: [Descriptor] = []
        for entry in archiveManifest {
            let configURL = try Self.archiveMemberURL(entry.config, relativeTo: directory)
            let configBlob = try Self.copyBlob(from: configURL, to: blobsDirectory)
            let configDescriptor = Descriptor(mediaType: Self.ociConfigMediaType, digest: configBlob.digest, size: configBlob.size)

            var layerDescriptors: [Descriptor] = []
            for layer in entry.layers {
                let layerURL = try Self.archiveMemberURL(layer, relativeTo: directory)
                let layerBlob = try Self.copyBlob(from: layerURL, to: blobsDirectory)
                layerDescriptors.append(Descriptor(mediaType: try Self.layerMediaType(for: layerURL), digest: layerBlob.digest, size: layerBlob.size))
            }

            let imageManifest = ImageManifest(schemaVersion: 2, config: configDescriptor, layers: layerDescriptors)
            let manifestData = try Self.encode(imageManifest)
            let manifestDigest = Self.digest(manifestData)
            try manifestData.write(to: blobsDirectory.appendingPathComponent(manifestDigest.digestValue), options: .atomic)

            let imageConfig = try? decoder.decode(DockerImageConfig.self, from: Data(contentsOf: configURL))
            let tags = entry.repoTags.filter { !$0.isEmpty && $0 != "<none>:<none>" }
            if tags.isEmpty {
                indexDescriptors.append(Descriptor(mediaType: Self.ociManifestMediaType, digest: manifestDigest.digest, size: manifestDigest.size, platform: imageConfig?.platform))
            } else {
                for tag in tags {
                    indexDescriptors.append(
                        Descriptor(
                            mediaType: Self.ociManifestMediaType,
                            digest: manifestDigest.digest,
                            size: manifestDigest.size,
                            annotations: [Self.refNameAnnotation: tag],
                            platform: imageConfig?.platform
                        ))
                }
            }
        }

        let index = ImageIndex(schemaVersion: 2, mediaType: Self.ociLayoutMediaType, manifests: indexDescriptors)
        try Self.encode(index).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        try Self.encode(ImageLayout(imageLayoutVersion: "1.0.0")).write(to: directory.appendingPathComponent(Self.ociLayoutFile), options: .atomic)
    }

    private static func archiveMemberURL(_ member: String, relativeTo directory: URL) throws -> URL {
        guard !member.hasPrefix("/") && !member.split(separator: "/").contains("..") else {
            throw ContainerizationError(.invalidArgument, message: "docker archive member escapes image directory: \(member)")
        }
        return URL(fileURLWithPath: member, relativeTo: directory).standardizedFileURL
    }

    private static func copyBlob(from source: URL, to blobsDirectory: URL) throws -> Blob {
        let blob = try Self.digest(source)
        let destination = blobsDirectory.appendingPathComponent(blob.digestValue)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return blob
    }

    private static func layerMediaType(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let header = handle.readData(ofLength: 2)
        if header.count == 2 && header[header.startIndex] == 0x1f && header[header.index(after: header.startIndex)] == 0x8b {
            return Self.ociGzipLayerMediaType
        }
        return Self.ociLayerMediaType
    }

    private static func digest(_ url: URL) throws -> Blob {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        var size = 0
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty {
                break
            }
            size += data.count
            hasher.update(data: data)
        }

        let digestValue = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Blob(digest: "sha256:\(digestValue)", digestValue: digestValue, size: size)
    }

    private static func digest(_ data: Data) -> Blob {
        let digestValue = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Blob(digest: "sha256:\(digestValue)", digestValue: digestValue, size: data.count)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct DockerManifestEntry: Decodable {
    let config: String
    let repoTags: [String]
    let layers: [String]

    enum CodingKeys: String, CodingKey {
        case config = "Config"
        case repoTags = "RepoTags"
        case layers = "Layers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.config = try container.decode(String.self, forKey: .config)
        self.repoTags = try container.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        self.layers = try container.decode([String].self, forKey: .layers)
    }
}

private struct DockerImageConfig: Decodable {
    let architecture: String?
    let os: String?
    let variant: String?

    var platform: Platform? {
        guard let architecture, let os else {
            return nil
        }
        return Platform(architecture: architecture, os: os, variant: variant)
    }
}

private struct Blob {
    let digest: String
    let digestValue: String
    let size: Int
}

private struct ImageLayout: Encodable {
    let imageLayoutVersion: String
}

private struct ImageIndex: Encodable {
    let schemaVersion: Int
    let mediaType: String
    let manifests: [Descriptor]
}

private struct ImageManifest: Encodable {
    let schemaVersion: Int
    let config: Descriptor
    let layers: [Descriptor]
}

private struct Descriptor: Encodable {
    let mediaType: String
    let digest: String
    let size: Int
    let annotations: [String: String]?
    let platform: Platform?

    init(mediaType: String, digest: String, size: Int, annotations: [String: String]? = nil, platform: Platform? = nil) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.annotations = annotations
        self.platform = platform
    }
}

private struct Platform: Encodable {
    let architecture: String
    let os: String
    let variant: String?
}
