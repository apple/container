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
import ContainerizationOS
import CryptoKit
import Foundation
import SystemPackage

struct DockerArchiveConverter {
    private static let ociLayoutName: FilePath.Component = "oci-layout"
    private static let dockerManifestName: FilePath.Component = "manifest.json"
    private static let indexName: FilePath.Component = "index.json"
    private static let blobsName: FilePath.Component = "blobs"
    private static let sha256Name: FilePath.Component = "sha256"

    private static let ociLayoutMediaType = "application/vnd.oci.image.index.v1+json"
    private static let ociManifestMediaType = "application/vnd.oci.image.manifest.v1+json"
    private static let ociConfigMediaType = "application/vnd.oci.image.config.v1+json"
    private static let ociLayerMediaType = "application/vnd.oci.image.layer.v1.tar"
    private static let ociGzipLayerMediaType = "application/vnd.oci.image.layer.v1.tar+gzip"
    private static let refNameAnnotation = "org.opencontainers.image.ref.name"

    static func convertIfNeeded(at directory: URL) throws {
        let root = try FileDescriptor.open(FilePath(directory.path), .readOnly, options: [.directory, .noFollow, .closeOnExec])
        defer { try? root.close() }

        if try Self.isRegularFile(root, Self.ociLayoutName) {
            return
        }
        guard try Self.isRegularFile(root, Self.dockerManifestName) else {
            return
        }
        try Self.convert(root: root)
    }

    private static func convert(root: FileDescriptor) throws {
        let manifestData: Data
        do {
            let manifestFile = try Self.openRelative(root, Self.path(Self.dockerManifestName), display: Self.dockerManifestName.string)
            defer { try? manifestFile.close() }
            manifestData = try Self.readAll(manifestFile)
        }

        let decoder = JSONDecoder()
        let archiveManifest = try decoder.decode([DockerManifestEntry].self, from: manifestData)
        let blobsDirectory = try Self.openBlobsDirectory(root)
        defer { try? blobsDirectory.close() }

        var indexDescriptors: [Descriptor] = []
        for entry in archiveManifest {
            let configData: Data
            let configBlob: Blob
            do {
                let configFile = try Self.openMember(root, entry.config)
                defer { try? configFile.close() }
                configData = try Self.readAll(configFile)
                configBlob = Self.digest(configData)
                try Self.writeBlob(configBlob, to: blobsDirectory) { destination in
                    try destination.writeAll(configData)
                }
            }
            let configDescriptor = Descriptor(mediaType: Self.ociConfigMediaType, digest: configBlob.digest, size: configBlob.size)

            var layerDescriptors: [Descriptor] = []
            for layer in entry.layers {
                let layerFile = try Self.openMember(root, layer)
                defer { try? layerFile.close() }
                let digested = try Self.digest(layerFile)
                try Self.writeBlob(digested.blob, to: blobsDirectory) { destination in
                    try Self.copy(layerFile, to: destination)
                }
                layerDescriptors.append(Descriptor(mediaType: Self.layerMediaType(for: digested.header), digest: digested.blob.digest, size: digested.blob.size))
            }

            let imageManifest = ImageManifest(schemaVersion: 2, config: configDescriptor, layers: layerDescriptors)
            let imageManifestData = try Self.encode(imageManifest)
            let manifestDigest = Self.digest(imageManifestData)
            try Self.writeBlob(manifestDigest, to: blobsDirectory) { destination in
                try destination.writeAll(imageManifestData)
            }

            let imageConfig = try? decoder.decode(DockerImageConfig.self, from: configData)
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
        try Self.writeReplacing(root, name: Self.indexName, data: try Self.encode(index))
        try Self.writeReplacing(root, name: Self.ociLayoutName, data: try Self.encode(ImageLayout(imageLayoutVersion: "1.0.0")))
    }

    private static func relativeMemberPath(_ member: String) throws -> FilePath {
        guard !member.isEmpty, !member.hasPrefix("/"), !member.contains("\0") else {
            throw Self.escapingMember(member)
        }
        var path = FilePath()
        var appended = false
        for piece in member.split(separator: "/", omittingEmptySubsequences: false) {
            guard let component = FilePath.Component(String(piece)), component.kind == .regular else {
                throw Self.escapingMember(member)
            }
            path.append(component)
            appended = true
        }
        guard appended else {
            throw Self.escapingMember(member)
        }
        return path
    }

    private static func openMember(_ root: FileDescriptor, _ member: String) throws -> FileDescriptor {
        try Self.openRelative(root, try Self.relativeMemberPath(member), display: member)
    }

    private static func openRelative(_ root: FileDescriptor, _ path: FilePath, display: String) throws -> FileDescriptor {
        do {
            return try FileDescriptorOps.openFile(root, relativePath: path, symlinks: .refuse)
        } catch let error as FileDescriptorOps.Error {
            switch error {
            case .cannotFollowSymlink, .invalidRelativePath:
                throw Self.escapingMember(display)
            default:
                throw error
            }
        }
    }

    private static func openBlobsDirectory(_ root: FileDescriptor) throws -> FileDescriptor {
        var relative = FilePath()
        relative.append(Self.blobsName)
        relative.append(Self.sha256Name)
        try FileDescriptorOps.mkdir(root, relative, makeIntermediates: true)
        let blobsDirectory = try FileDescriptorOps.openDirectory(root, Self.blobsName)
        defer { try? blobsDirectory.close() }
        return try FileDescriptorOps.openDirectory(blobsDirectory, Self.sha256Name)
    }

    private static func isRegularFile(_ directory: FileDescriptor, _ name: FilePath.Component) throws -> Bool {
        try FileDescriptorOps.entryType(directory, name) == .regular
    }

    private static func path(_ component: FilePath.Component) -> FilePath {
        var path = FilePath()
        path.append(component)
        return path
    }

    private static func writeBlob(_ blob: Blob, to directory: FileDescriptor, write: (FileDescriptor) throws -> Void) throws {
        guard let name = FilePath.Component(blob.digestValue), name.kind == .regular else {
            throw ContainerizationError(.internalError, message: "invalid blob digest \(blob.digest)")
        }
        if let existing = try FileDescriptorOps.entryType(directory, name) {
            if existing == .regular {
                return
            }
            try FileDescriptorOps.unlink(directory, name)
        }
        let destination = try FileDescriptorOps.createFile(directory, name)
        defer { try? destination.close() }
        try write(destination)
    }

    private static func writeReplacing(_ directory: FileDescriptor, name: FilePath.Component, data: Data) throws {
        if try FileDescriptorOps.entryType(directory, name) != nil {
            try FileDescriptorOps.unlink(directory, name)
        }
        let destination = try FileDescriptorOps.createFile(directory, name)
        defer { try? destination.close() }
        try destination.writeAll(data)
    }

    private static func copy(_ source: FileDescriptor, to destination: FileDescriptor) throws {
        try source.seek(offset: 0, from: .start)
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { rawBuffer in
                try source.read(into: rawBuffer)
            }
            if count == 0 {
                break
            }
            try destination.writeAll(buffer.prefix(count))
        }
    }

    private static func readAll(_ fd: FileDescriptor) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { rawBuffer in
                try fd.read(into: rawBuffer)
            }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func layerMediaType(for header: Data) -> String {
        if header.count >= 2, header[header.startIndex] == 0x1f, header[header.index(after: header.startIndex)] == 0x8b {
            return Self.ociGzipLayerMediaType
        }
        return Self.ociLayerMediaType
    }

    private static func digest(_ fd: FileDescriptor) throws -> (blob: Blob, header: Data) {
        var hasher = SHA256()
        var size = 0
        var header = Data()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { rawBuffer in
                try fd.read(into: rawBuffer)
            }
            if count == 0 {
                break
            }
            let bytes = Data(buffer.prefix(count))
            if header.count < 2 {
                header.append(bytes.prefix(2 - header.count))
            }
            size += count
            hasher.update(data: bytes)
        }
        return (Self.blob(digestValue: Self.hex(hasher.finalize()), size: size), header)
    }

    private static func digest(_ data: Data) -> Blob {
        Self.blob(digestValue: Self.hex(SHA256.hash(data: data)), size: data.count)
    }

    private static func blob(digestValue: String, size: Int) -> Blob {
        Blob(digest: "sha256:\(digestValue)", digestValue: digestValue, size: size)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func escapingMember(_ member: String) -> ContainerizationError {
        ContainerizationError(.invalidArgument, message: "docker archive member escapes image directory: \(member)")
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
