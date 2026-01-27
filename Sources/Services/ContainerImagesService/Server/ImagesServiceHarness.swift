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

import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging

public struct ImagesServiceHarness: Sendable {
    let log: Logging.Logger
    let service: ImagesService

    public init(service: ImagesService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func pull(_ message: XPCMessage) async throws -> XPCMessage {
        let ref = message.string(key: .imageReference)
        guard let ref else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing image reference"
            )
        }
        let platformData = message.dataNoCopy(key: .ociPlatform)
        var platform: Platform? = nil
        if let platformData {
            platform = try JSONDecoder().decode(ContainerizationOCI.Platform.self, from: platformData)
        }
        let insecure = message.bool(key: .insecureFlag)
        let maxConcurrentDownloads = message.int64(key: .maxConcurrentDownloads)

        let progressUpdateService = ProgressUpdateService(message: message)
        let imageDescription = try await service.pull(
            reference: ref, platform: platform, insecure: insecure, progressUpdate: progressUpdateService?.handler, maxConcurrentDownloads: Int(maxConcurrentDownloads))

        let imageData = try JSONEncoder().encode(imageDescription)
        let reply = message.reply()
        reply.set(key: .imageDescription, value: imageData)
        return reply
    }

    @Sendable
    public func push(_ message: XPCMessage) async throws -> XPCMessage {
        let ref = message.string(key: .imageReference)
        guard let ref else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing image reference"
            )
        }
        let platformData = message.dataNoCopy(key: .ociPlatform)
        var platform: Platform? = nil
        if let platformData {
            platform = try JSONDecoder().decode(ContainerizationOCI.Platform.self, from: platformData)
        }
        let insecure = message.bool(key: .insecureFlag)

        let progressUpdateService = ProgressUpdateService(message: message)
        try await service.push(reference: ref, platform: platform, insecure: insecure, progressUpdate: progressUpdateService?.handler)

        let reply = message.reply()
        return reply
    }

    @Sendable
    public func tag(_ message: XPCMessage) async throws -> XPCMessage {
        let old = message.string(key: .imageReference)
        guard let old else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing image reference"
            )
        }
        let new = message.string(key: .imageNewReference)
        guard let new else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing new image reference"
            )
        }
        let newDescription = try await service.tag(old: old, new: new)
        let descData = try JSONEncoder().encode(newDescription)
        let reply = message.reply()
        reply.set(key: .imageDescription, value: descData)
        return reply
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let images = try await service.list()
        let imageData = try JSONEncoder().encode(images)
        let reply = message.reply()
        reply.set(key: .imageDescriptions, value: imageData)
        return reply
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let ref = message.string(key: .imageReference)
        guard let ref else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing image reference"
            )
        }
        let garbageCollect = message.bool(key: .garbageCollect)
        try await self.service.delete(reference: ref, garbageCollect: garbageCollect)
        let reply = message.reply()
        return reply
    }

    @Sendable
    public func save(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .imageDescriptions)
        guard let data else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing image description"
            )
        }
        let imageDescriptions = try JSONDecoder().decode([ImageDescription].self, from: data)
        let references = imageDescriptions.map { $0.reference }

        let platformData = message.dataNoCopy(key: .ociPlatform)
        var platform: Platform? = nil
        if let platformData {
            platform = try JSONDecoder().decode(ContainerizationOCI.Platform.self, from: platformData)
        }
        let out = message.string(key: .filePath)
        guard let out else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing output file path"
            )
        }
        try await service.save(references: references, out: URL(filePath: out), platform: platform)
        let reply = message.reply()
        return reply
    }

    @Sendable
    public func load(_ message: XPCMessage) async throws -> XPCMessage {
        let input = message.string(key: .filePath)
        let force = message.bool(key: .forceLoad)
        guard let input else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing input file path"
            )
        }
        let (images, rejectedMembers) = try await service.load(
            from: URL(filePath: input),
            force: force
        )
        let reply = message.reply()
        let imagesData = try JSONEncoder().encode(images)
        reply.set(key: .imageDescriptions, value: imagesData)
        let rejectedData = try JSONEncoder().encode(rejectedMembers)
        reply.set(key: .rejectedMembers, value: rejectedData)
        return reply
    }

    @Sendable
    public func cleanupOrphanedBlobs(_ message: XPCMessage) async throws -> XPCMessage {
        let (deleted, size) = try await service.cleanupOrphanedBlobs()
        let reply = message.reply()
        let data = try JSONEncoder().encode(deleted)
        reply.set(key: .digests, value: data)
        reply.set(key: .imageSize, value: size)
        return reply
    }

    @Sendable
    public func calculateDiskUsage(_ message: XPCMessage) async throws -> XPCMessage {
        // Decode active image references from the message
        let activeRefsData = message.dataNoCopy(key: .activeImageReferences)
        let activeRefs: Set<String>
        if let activeRefsData {
            activeRefs = try JSONDecoder().decode(Set<String>.self, from: activeRefsData)
        } else {
            activeRefs = Set<String>()
        }

        let (total, active, size, reclaimable) = try await service.calculateDiskUsage(activeReferences: activeRefs)

        let reply = message.reply()
        reply.set(key: .totalCount, value: Int64(total))
        reply.set(key: .activeCount, value: Int64(active))
        reply.set(key: .imageSize, value: size)
        reply.set(key: .reclaimableSize, value: reclaimable)
        return reply
    }
}

// MARK: Image Snapshot Methods

extension ImagesServiceHarness {
    @Sendable
    public func unpack(_ message: XPCMessage) async throws -> XPCMessage {
        let descriptionData = message.dataNoCopy(key: .imageDescription)
        guard let descriptionData else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing Image description"
            )
        }
        let description = try JSONDecoder().decode(ImageDescription.self, from: descriptionData)
        var platform: Platform?
        if let platformData = message.dataNoCopy(key: .ociPlatform) {
            platform = try JSONDecoder().decode(ContainerizationOCI.Platform.self, from: platformData)
        }

        let progressUpdateService = ProgressUpdateService(message: message)
        try await self.service.unpack(description: description, platform: platform, progressUpdate: progressUpdateService?.handler)

        let reply = message.reply()
        return reply
    }

    @Sendable
    public func deleteSnapshot(_ message: XPCMessage) async throws -> XPCMessage {
        let descriptionData = message.dataNoCopy(key: .imageDescription)
        guard let descriptionData else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing image description"
            )
        }
        let description = try JSONDecoder().decode(ImageDescription.self, from: descriptionData)
        let platformData = message.dataNoCopy(key: .ociPlatform)
        var platform: Platform?
        if let platformData {
            platform = try JSONDecoder().decode(ContainerizationOCI.Platform.self, from: platformData)
        }
        try await self.service.deleteImageSnapshot(description: description, platform: platform)
        let reply = message.reply()
        return reply
    }

    @Sendable
    public func getSnapshot(_ message: XPCMessage) async throws -> XPCMessage {
        let descriptionData = message.dataNoCopy(key: .imageDescription)
        guard let descriptionData else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing image description"
            )
        }
        let description = try JSONDecoder().decode(ImageDescription.self, from: descriptionData)
        let platformData = message.dataNoCopy(key: .ociPlatform)
        guard let platformData else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing OCI platform"
            )
        }
        let platform = try JSONDecoder().decode(ContainerizationOCI.Platform.self, from: platformData)
        let fs = try await self.service.getImageSnapshot(description: description, platform: platform)
        let fsData = try JSONEncoder().encode(fs)
        let reply = message.reply()
        reply.set(key: .filesystem, value: fsData)
        return reply
    }
}
