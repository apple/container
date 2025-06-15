//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerImagesServiceClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

// MARK: ClientImage structure

public struct ClientImage: Sendable {
    private let contentStore: ContentStore = RemoteContentStoreClient()
    public let description: ImageDescription

    public var digest: String { description.digest }
    public var descriptor: Descriptor { description.descriptor }
    public var reference: String { description.reference }

    public init(description: ImageDescription) {
        self.description = description
    }

    /// Returns the underlying OCI index for the image.
    public func index() async throws -> Index {
        guard let content: Content = try await contentStore.get(digest: description.digest) else {
            throw ContainerizationError(.notFound, message: "Content with digest \(description.digest)")
        }
        return try content.decode()
    }

    /// Returns the manifest for the specified platform.
    public func manifest(for platform: Platform) async throws -> Manifest {
        let index = try await self.index()
        let desc = index.manifests.first { desc in
            desc.platform == platform
        }
        guard let desc else {
            throw ContainerizationError(.unsupported, message: "Platform \(platform.description)")
        }
        guard let content: Content = try await contentStore.get(digest: desc.digest) else {
            throw ContainerizationError(.notFound, message: "Content with digest \(desc.digest)")
        }
        return try content.decode()
    }

    /// Returns the OCI config for the specified platform.
    public func config(for platform: Platform) async throws -> ContainerizationOCI.Image {
        let manifest = try await self.manifest(for: platform)
        let desc = manifest.config
        guard let content: Content = try await contentStore.get(digest: desc.digest) else {
            throw ContainerizationError(.notFound, message: "Content with digest \(desc.digest)")
        }
        return try content.decode()
    }
}

// MARK: ClientImage constants

extension ClientImage {
    private static let serviceIdentifier = "com.apple.container.core.container-core-images"
    public static let initImageRef = ClientDefaults.get(key: .defaultInitImage)

    private static func newXPCClient() -> XPCClient {
        XPCClient(service: Self.serviceIdentifier)
    }

    private static func newRequest(_ route: ImagesServiceXPCRoute) -> XPCMessage {
        XPCMessage(route: route)
    }

    private static var defaultRegistryDomain: String {
        ClientDefaults.get(key: .defaultRegistryDomain)
    }
}

// MARK: Static methods

extension ClientImage {
    private static let legacyDockerRegistryHost = "docker.io"
    private static let dockerRegistryHost = "registry-1.docker.io"
    private static let defaultDockerRegistryRepo = "library"

    public static func normalizeReference(_ ref: String) throws -> String {
        guard ref != Self.initImageRef else {
            // Don't modify the default init image reference.
            // This is to allow for easier local development against
            // an updated containerization.
            return ref
        }
        // Check if the input reference has a domain specified
        var updatedRawReference: String = ref
        let r = try Reference.parse(ref)
        if r.domain == nil {
            updatedRawReference = "\(Self.defaultRegistryDomain)/\(ref)"
        }

        let updatedReference = try Reference.parse(updatedRawReference)

        // Handle adding the :latest tag if it isn't specified,
        // as well as adding the "library/" repository if it isn't set only if the host is docker.io
        updatedReference.normalize()
        return updatedReference.description
    }

    public static func denormalizeReference(_ ref: String) throws -> String {
        var updatedRawReference: String = ref
        let r = try Reference.parse(ref)
        let defaultRegistry = Self.defaultRegistryDomain
        if r.domain == defaultRegistry {
            updatedRawReference = "\(r.path)"
            if let tag = r.tag {
                updatedRawReference += ":\(tag)"
            } else if let digest = r.digest {
                updatedRawReference += "@\(digest)"
            }
            if defaultRegistry == dockerRegistryHost || defaultRegistry == legacyDockerRegistryHost {
                updatedRawReference.trimPrefix("\(defaultDockerRegistryRepo)/")
            }
        }
        return updatedRawReference
    }

    public static func list() async throws -> [ClientImage] {
        let client = newXPCClient()
        let request = newRequest(.imageList)
        let response = try await client.send(request)

        let imageDescriptions = try response.imageDescriptions()
        return imageDescriptions.map { desc in
            ClientImage(description: desc)
        }
    }

    public static func get(names: [String]) async throws -> (images: [ClientImage], error: [String]) {
        let all = try await self.list()
        var errors: [String] = []
        var found: [ClientImage] = []
        for name in names {
            do {
                guard let img = try Self._search(reference: name, in: all) else {
                    errors.append(name)
                    continue
                }
                found.append(img)
            } catch {
                errors.append(name)
            }
        }
        return (found, errors)
    }

    public static func get(reference: String) async throws -> ClientImage {
        let all = try await self.list()
        guard let found = try self._search(reference: reference, in: all) else {
            throw ContainerizationError(.notFound, message: "Image with reference \(reference)")
        }
        return found
    }

    private static func _search(reference: String, in all: [ClientImage]) throws -> ClientImage? {
        let locallyBuiltImage = try {
            // Check if we have an image whose index descriptor contains the image name
            // as an annotation. Prefer this in all cases, since these are locally built images.
            let r = try Reference.parse(reference)
            r.normalize()
            let withDefaultTag = r.description

            let localImageMatches = all.filter { $0.description.nameFromAnnotation() == withDefaultTag }
            guard localImageMatches.count > 1 else {
                return localImageMatches.first
            }
            // More than one image matched. Check against the tagged reference
            return localImageMatches.first { $0.reference == withDefaultTag }
        }()
        if let locallyBuiltImage {
            return locallyBuiltImage
        }
        // If we don't find a match, try matching `ImageDescription.name` against the given
        // input string, while also checking against its normalized form.
        // Return the first match.
        let normalizedReference = try Self.normalizeReference(reference)
        return all.first(where: { image in
            image.reference == reference || image.reference == normalizedReference
        })
    }

    public static func pull(reference: String, platform: Platform? = nil, scheme: RequestScheme = .auto, progressUpdate: ProgressUpdateHandler? = nil) async throws -> ClientImage {
        let client = newXPCClient()
        let request = newRequest(.imagePull)

        let reference = try self.normalizeReference(reference)
        guard let host = try Reference.parse(reference).domain else {
            throw ContainerizationError(.invalidArgument, message: "Could not extract host from reference \(reference)")
        }

        request.set(key: .imageReference, value: reference)
        try request.set(platform: platform)

        let insecure = try scheme.schemeFor(host: host) == .http
        request.set(key: .insecureFlag, value: insecure)

        var progressUpdateClient: ProgressUpdateClient?
        if let progressUpdate {
            progressUpdateClient = await ProgressUpdateClient(for: progressUpdate, request: request)
        }

        let response = try await client.send(request)
        let description = try response.imageDescription()
        let image = ClientImage(description: description)

        await progressUpdateClient?.finish()
        return image
    }

    public static func delete(reference: String, garbageCollect: Bool = false) async throws {
        let client = newXPCClient()
        let request = newRequest(.imageDelete)
        request.set(key: .imageReference, value: reference)
        request.set(key: .garbageCollect, value: garbageCollect)
        let _ = try await client.send(request)
    }

    public static func load(from tarFile: String) async throws -> [ClientImage] {
        let client = newXPCClient()
        let request = newRequest(.imageLoad)
        request.set(key: .filePath, value: tarFile)
        let reply = try await client.send(request)

        let loaded = try reply.imageDescriptions()
        return loaded.map { desc in
            ClientImage(description: desc)
        }
    }

    public static func pruneImages() async throws -> ([String], UInt64) {
        let client = newXPCClient()
        let request = newRequest(.imagePrune)
        let response = try await client.send(request)
        let digests = try response.digests()
        let size = response.uint64(key: .size)
        return (digests, size)
    }

    public static func fetch(reference: String, platform: Platform? = nil, scheme: RequestScheme = .auto, progressUpdate: ProgressUpdateHandler? = nil) async throws -> ClientImage
    {
        do {
            let match = try await self.get(reference: reference)
            if let platform {
                // The image exists, but we dont know if we have the right platform pulled
                // Check if we do, if not pull the requested platform
                _ = try await match.config(for: platform)
            }
            return match
        } catch let err as ContainerizationError {
            guard err.isCode(.notFound) else {
                throw err
            }
            return try await Self.pull(reference: reference, platform: platform, scheme: scheme, progressUpdate: progressUpdate)
        }
    }
}

// MARK: Instance methods

extension ClientImage {
    public func push(platform: Platform? = nil, scheme: RequestScheme, progressUpdate: ProgressUpdateHandler?) async throws {
        let client = Self.newXPCClient()
        let request = Self.newRequest(.imagePush)

        guard let host = try Reference.parse(reference).domain else {
            throw ContainerizationError(.invalidArgument, message: "Could not extract host from reference \(reference)")
        }
        request.set(key: .imageReference, value: reference)

        let insecure = try scheme.schemeFor(host: host) == .http
        request.set(key: .insecureFlag, value: insecure)

        try request.set(platform: platform)

        var progressUpdateClient: ProgressUpdateClient?
        if let progressUpdate {
            progressUpdateClient = await ProgressUpdateClient(for: progressUpdate, request: request)
        }
        _ = try await client.send(request)
        await progressUpdateClient?.finish()
    }

    @discardableResult
    public func tag(new: String) async throws -> ClientImage {
        let client = Self.newXPCClient()
        let request = Self.newRequest(.imageTag)
        request.set(key: .imageReference, value: self.description.reference)
        request.set(key: .imageNewReference, value: new)
        let reply = try await client.send(request)
        let description = try reply.imageDescription()
        return ClientImage(description: description)
    }

    // MARK: Snapshot Methods

    public func save(out: String, platform: Platform? = nil) async throws {
        let client = Self.newXPCClient()
        let request = Self.newRequest(.imageSave)
        try request.set(description: self.description)
        request.set(key: .filePath, value: out)
        try request.set(platform: platform)
        let _ = try await client.send(request)
    }

    public func unpack(platform: Platform?, progressUpdate: ProgressUpdateHandler? = nil) async throws {
        let client = Self.newXPCClient()
        let request = Self.newRequest(.imageUnpack)

        try request.set(description: description)
        try request.set(platform: platform)

        var progressUpdateClient: ProgressUpdateClient?
        if let progressUpdate {
            progressUpdateClient = await ProgressUpdateClient(for: progressUpdate, request: request)
        }

        try await client.send(request)

        await progressUpdateClient?.finish()
    }

    public func deleteSnapshot(platform: Platform?) async throws {
        let client = Self.newXPCClient()
        let request = Self.newRequest(.snapshotDelete)

        try request.set(description: description)
        try request.set(platform: platform)

        try await client.send(request)
    }

    public func getSnapshot(platform: Platform) async throws -> Filesystem {
        let client = Self.newXPCClient()
        let request = Self.newRequest(.snapshotGet)

        try request.set(description: description)
        try request.set(platform: platform)

        let response = try await client.send(request)
        let fs = try response.filesystem()
        return fs
    }

    @discardableResult
    public func getCreateSnapshot(platform: Platform, progressUpdate: ProgressUpdateHandler? = nil) async throws -> Filesystem {
        do {
            return try await self.getSnapshot(platform: platform)
        } catch let err as ContainerizationError {
            guard err.code == .notFound else {
                throw err
            }
            try await self.unpack(platform: platform, progressUpdate: progressUpdate)
            return try await self.getSnapshot(platform: platform)
        }
    }
}

extension XPCMessage {
    fileprivate func set(description: ImageDescription) throws {
        let descData = try JSONEncoder().encode(description)
        self.set(key: .imageDescription, value: descData)
    }

    fileprivate func set(descriptions: [ImageDescription]) throws {
        let descData = try JSONEncoder().encode(descriptions)
        self.set(key: .imageDescriptions, value: descData)
    }

    fileprivate func set(platform: Platform?) throws {
        guard let platform else {
            return
        }
        let platformData = try JSONEncoder().encode(platform)
        self.set(key: .ociPlatform, value: platformData)
    }

    fileprivate func imageDescription() throws -> ImageDescription {
        let responseData = self.dataNoCopy(key: .imageDescription)
        guard let responseData else {
            throw ContainerizationError(.empty, message: "imageDescription not received")
        }
        let description = try JSONDecoder().decode(ImageDescription.self, from: responseData)
        return description
    }

    fileprivate func imageDescriptions() throws -> [ImageDescription] {
        let responseData = self.dataNoCopy(key: .imageDescriptions)
        guard let responseData else {
            throw ContainerizationError(.empty, message: "imageDescriptions not received")
        }
        let descriptions = try JSONDecoder().decode([ImageDescription].self, from: responseData)
        return descriptions
    }

    fileprivate func filesystem() throws -> Filesystem {
        let responseData = self.dataNoCopy(key: .filesystem)
        guard let responseData else {
            throw ContainerizationError(.empty, message: "filesystem not received")
        }
        let fs = try JSONDecoder().decode(Filesystem.self, from: responseData)
        return fs
    }

    fileprivate func digests() throws -> [String] {
        let responseData = self.dataNoCopy(key: .digests)
        guard let responseData else {
            throw ContainerizationError(.empty, message: "digests not received")
        }
        let digests = try JSONDecoder().decode([String].self, from: responseData)
        return digests
    }
}

extension ImageDescription {
    fileprivate func nameFromAnnotation() -> String? {
        guard let annotations = self.descriptor.annotations else {
            return nil
        }
        guard let name = annotations[AnnotationKeys.containerizationImageName] else {
            return nil
        }
        return name
    }
}
