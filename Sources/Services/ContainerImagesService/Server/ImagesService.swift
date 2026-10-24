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

import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

public actor ImagesService {
    private let log: Logger
    private let contentStore: ContentStore
    private let imageStore: ImageStore
    private let snapshotStore: SnapshotStore
    private let containerSystemConfig: ContainerSystemConfig

    public init(
        contentStore: ContentStore,
        imageStore: ImageStore,
        snapshotStore: SnapshotStore,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger
    ) throws {
        self.contentStore = contentStore
        self.imageStore = imageStore
        self.snapshotStore = snapshotStore
        self.containerSystemConfig = containerSystemConfig
        self.log = log
    }

    private func _list() async throws -> [Containerization.Image] {
        try await imageStore.list()
    }

    private func _get(_ reference: String) async throws -> Containerization.Image {
        try await imageStore.get(reference: reference)
    }

    private func _get(_ description: ImageDescription) async throws -> Containerization.Image {
        let exists = try await self._get(description.reference)
        guard exists.descriptor == description.descriptor else {
            throw ContainerizationError(.invalidState, message: "descriptor mismatch: expected \(description.descriptor), got \(exists.descriptor)")
        }
        return exists
    }

    public func list() async throws -> [ImageDescription] {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        try await self.removeLegacyShadows()
        return try await imageStore.list().map { $0.description.fromCZ }
    }

    public func pull(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?, maxConcurrentDownloads: Int = 3) async throws
        -> ImageDescription
    {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
                "platform": "\(String(describing: platform))",
                "insecure": "\(insecure)",
                "maxConcurrentDownloads": "\(maxConcurrentDownloads)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await Self.withAuthentication(ref: reference) { auth in
            try await self.imageStore.pull(
                reference: reference, platform: platform, insecure: insecure, auth: auth, progress: ContainerizationProgressAdapter.handler(from: progressUpdate),
                maxConcurrentDownloads: maxConcurrentDownloads)
        }
        guard let img else {
            throw ContainerizationError(.internalError, message: "failed to pull image \(reference)")
        }
        return img.description.fromCZ
    }

    public func platforms(reference: String, insecure: Bool) async throws -> [Platform] {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
            ]
        )

        let platforms = try await Self.withAuthentication(ref: reference) { auth in
            try await self.imageStore.platforms(reference: reference, insecure: insecure, auth: auth)
        }
        guard let platforms else {
            throw ContainerizationError(.internalError, message: "failed to read platforms of image \(reference)")
        }
        return platforms
    }

    public func push(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
                "platform": "\(String(describing: platform))",
                "insecure": "\(insecure)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        try await Self.withAuthentication(ref: reference) { auth in
            try await self.imageStore.push(
                reference: reference, platform: platform, insecure: insecure, auth: auth, progress: ContainerizationProgressAdapter.handler(from: progressUpdate))
        }
    }

    public func tag(old: String, new: String) async throws -> ImageDescription {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "old": "\(old)",
                "new": "\(new)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "old": "\(old)",
                    "new": "\(new)",
                ]
            )
        }

        let fullyQualified = try ClientImage.normalizeReference(new, containerSystemConfig: self.containerSystemConfig)
        let plan = try await self.legacyPlan(for: fullyQualified, preserving: old)
        try await self.renameLegacyReference(plan, to: fullyQualified)
        let img = try await self.imageStore.tag(existing: old, new: fullyQualified)
        try await self.dropLegacyReferences(plan)
        return img.description.fromCZ
    }

    public func delete(reference: String, garbageCollect: Bool) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                ]
            )
        }

        try await self.imageStore.delete(reference: reference, performCleanup: garbageCollect)
    }

    public func save(references: [String], out: URL, platform: Platform?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "references": "\(references)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "references": "\(references)",
                ]
            )
        }

        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await self.imageStore.save(references: references, out: tempDir, platform: platform)
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: out)
        try writer.archiveDirectory(tempDir)
        try writer.finishEncoding()
    }

    public func load(from tarFile: URL, force: Bool) async throws -> ([ImageDescription], [String]) {
        let archivePathname = tarFile.absolutePath()
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "archivePath": "\(archivePathname)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "archivePath": "\(archivePathname)",
                ]
            )
        }

        let reader = try ArchiveReader(file: tarFile)
        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let rejectedMembers = try reader.extractContents(to: tempDir)
        guard rejectedMembers.isEmpty || force else {
            throw ContainerizationError(.invalidArgument, message: "cannot load tar image with rejected paths: \(rejectedMembers)")
        }

        let loaded = try await self.imageStore.load(from: tempDir)
        var images: [ImageDescription] = []
        for image in loaded {
            let fullyQualified = try ClientImage.normalizeReference(image.reference, containerSystemConfig: self.containerSystemConfig)
            let plan = try await self.legacyPlan(for: fullyQualified, preserving: image.reference)
            try await self.renameLegacyReference(plan, to: fullyQualified)
            try await self.dropLegacyReferences(plan, preserving: image.reference)
            images.append(image.description.fromCZ)
        }
        return (images, rejectedMembers)
    }

    public func cleanUpOrphanedBlobs() async throws -> ([String], UInt64) {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        let images = try await self._list()
        let freedSnapshotBytes = try await self.snapshotStore.clean(keepingSnapshotsFor: images)
        let (deleted, freedContentBytes) = try await self.imageStore.cleanUpOrphanedBlobs()
        return (deleted, freedContentBytes + freedSnapshotBytes)
    }

    /// Calculate disk usage for images
    /// - Parameter activeReferences: Set of image references currently in use by containers
    public func calculateDiskUsage(activeReferences: Set<String>) async throws -> (totalCount: Int, activeCount: Int, totalSize: UInt64, reclaimableSize: UInt64) {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "references": "\(activeReferences)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "references": "\(activeReferences)",
                ]
            )
        }

        let images = try await self._list()
        var activeCount = 0
        var activeContentSizes: [String: UInt64] = [:]
        var activeSnapshotSizes: [String: UInt64] = [:]
        var processedDigests = Set<String>()

        for image in images {
            guard activeReferences.contains(image.reference) else { continue }
            activeCount += 1
            let imageDigest = try image.digest.validatedDigestEncoding()
            guard processedDigests.insert(imageDigest).inserted else { continue }

            for digest in try await image.referencedDigests() where activeContentSizes[digest] == nil {
                guard let content: Content = try await self.contentStore.get(digest: digest) else { continue }
                activeContentSizes[digest] = try self.contentDiskSize(content)
            }
            for (digest, size) in try await self.snapshotStore.getSnapshotSizes(for: image) {
                activeSnapshotSizes[digest] = size
            }
        }

        let snapshotDiskSize = await self.snapshotStore.totalAllocatedSize()
        let contentDiskTotal = try await self.contentStore.totalAllocatedSize()
        let totalOnDisk = contentDiskTotal + snapshotDiskSize
        let activeSize = activeContentSizes.values.reduce(0, +) + activeSnapshotSizes.values.reduce(0, +)
        let reclaimable = totalOnDisk > activeSize ? totalOnDisk - activeSize : 0

        return (images.count, activeCount, totalOnDisk, reclaimable)
    }

    /// Legacy short-name entries that denote `fullyQualified`.
    ///
    /// `preserving` is left out of the pre-write rename so the caller can still
    /// read that key. A following tag then overwrites the fully-qualified entry.
    private func legacyPlan(for fullyQualified: String, preserving: String?) async throws -> ImageReferenceNormalization.Plan {
        let stored = try await self.imageStore.list().map(\.reference)
        return ImageReferenceNormalization.plan(
            storedReferences: stored,
            fullyQualified: fullyQualified,
            preserving: preserving,
            containerSystemConfig: self.containerSystemConfig
        )
    }

    private func renameLegacyReference(_ plan: ImageReferenceNormalization.Plan, to fullyQualified: String) async throws {
        guard let renameFrom = plan.renameFrom else {
            return
        }
        self.log.debug(
            "normalizing legacy image reference",
            metadata: [
                "from": "\(renameFrom)",
                "to": "\(fullyQualified)",
            ]
        )
        let existing = try await self.imageStore.get(reference: renameFrom)
        _ = try await self.imageStore.create(
            description: Containerization.Image.Description(reference: fullyQualified, descriptor: existing.descriptor)
        )
    }

    private func dropLegacyReferences(_ plan: ImageReferenceNormalization.Plan, preserving: String? = nil) async throws {
        for reference in plan.drop where reference != preserving {
            self.log.debug(
                "removing legacy short-name image reference",
                metadata: [
                    "reference": "\(reference)"
                ]
            )
            try await self.imageStore.delete(reference: reference)
        }
    }

    /// Drops a short-name entry when the fully-qualified form of the same tag is already stored.
    private func removeLegacyShadows() async throws {
        let stored = try await self.imageStore.list().map(\.reference)
        let shadows = ImageReferenceNormalization.legacyShadows(
            storedReferences: stored,
            containerSystemConfig: self.containerSystemConfig
        )
        guard !shadows.isEmpty else {
            return
        }
        let plan = ImageReferenceNormalization.Plan(renameFrom: nil, drop: shadows)
        try await self.dropLegacyReferences(plan)
    }

    private func contentDiskSize(_ content: Content) throws -> UInt64 {
        let values = try? content.path.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        if let allocatedSize = values?.totalFileAllocatedSize {
            return UInt64(allocatedSize)
        }
        return try content.size()
    }
}

// MARK: Image Snapshot Methods

extension ImagesService {
    public func unpack(description: ImageDescription, platform: Platform?, progressUpdate: ProgressUpdateHandler?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        try await self.snapshotStore.unpack(image: img, platform: platform, progressUpdate: progressUpdate)
    }

    public func deleteImageSnapshot(description: ImageDescription, platform: Platform?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        try await self.snapshotStore.delete(for: img, platform: platform)
    }

    public func getImageSnapshot(description: ImageDescription, platform: Platform) async throws -> Filesystem {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        return try await self.snapshotStore.get(for: img, platform: platform)
    }
}

// MARK: Static Methods

extension ImagesService {
    private static func withAuthentication<T>(
        ref: String, _ body: @Sendable @escaping (_ auth: Authentication?) async throws -> T?
    ) async throws -> T? {
        var authentication: Authentication?
        let ref = try Reference.parse(ref)
        guard let host = ref.resolvedDomain else {
            throw ContainerizationError(.invalidArgument, message: "no host specified in image reference: \(ref)")
        }
        authentication = Self.authenticationFromEnv(host: host)
        if let authentication {
            return try await body(authentication)
        }
        let keychain = KeychainHelper(securityDomain: Constants.keychainID)
        do {
            authentication = try keychain.lookup(hostname: host)
        } catch let err as KeychainHelper.Error {
            guard case .keyNotFound = err else {
                throw ContainerizationError(.internalError, message: "error querying keychain for \(host)", cause: err)
            }
        }
        do {
            return try await body(authentication)
        } catch let err as RegistryClient.Error {
            guard case .invalidStatus(_, let status, _) = err else {
                throw err
            }
            guard status == .unauthorized || status == .forbidden else {
                throw err
            }
            guard authentication != nil else {
                throw ContainerizationError(.internalError, message: "\(String(describing: err)), no credentials found for host \(host)")
            }
            throw err
        }
    }

    private static func authenticationFromEnv(host: String) -> Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard env["CONTAINER_REGISTRY_HOST"] == host else {
            return nil
        }
        guard let user = env["CONTAINER_REGISTRY_USER"], let password = env["CONTAINER_REGISTRY_TOKEN"] else {
            return nil
        }
        return BasicAuthentication(username: user, password: password)
    }
}

extension ImageDescription {
    public var toCZ: Containerization.Image.Description {
        .init(reference: self.reference, descriptor: self.descriptor)
    }
}

extension Containerization.Image.Description {
    public var fromCZ: ImageDescription {
        .init(
            reference: self.reference,
            descriptor: self.descriptor
        )
    }
}
