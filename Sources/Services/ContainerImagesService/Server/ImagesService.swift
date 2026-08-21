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

    /// One landing, removal, or sweep at a time. The store operations
    /// suspend mid-flight, and the actor admits other calls at every
    /// suspension, so a garbage collection overlapping a landing computes
    /// its keep set without the arriving image and prunes blobs and
    /// snapshots the landing is about to reference. The lock is held
    /// across each whole mutating operation, the way PodsService holds
    /// its lock across lifecycle operations; containerd guards the same
    /// window with leases.
    /// https://github.com/containerd/containerd/blob/main/docs/garbage-collection.md
    private let lock = AsyncLock()

    public init(
        contentStore: ContentStore,
        imageStore: ImageStore,
        snapshotStore: SnapshotStore,
        log: Logger
    ) throws {
        self.contentStore = contentStore
        self.imageStore = imageStore
        self.snapshotStore = snapshotStore
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

    /// Sweep the snapshot directories no current image claims.
    ///
    /// An unpacked snapshot is owned by the record that names it, so a record
    /// that stops naming it leaves it owned by nobody: registering an image
    /// over an existing reference replaces the record, and removing a
    /// reference takes it away. Only the store sees either happen, so every
    /// path that lands or removes records runs this sweep afterwards. The
    /// sweep is housekeeping: its failure is loud in the log and never fails
    /// the operation that carried it.
    private func sweepReplacedSnapshots(after function: String = #function) async {
        do {
            let kept = try await self._list()
            let freedSnapshotBytes = try await self.snapshotStore.clean(keepingSnapshotsFor: kept)
            if freedSnapshotBytes > 0 {
                self.log.debug(
                    "ImagesService: swept snapshots of replaced images",
                    metadata: [
                        "func": "\(function)",
                        "freedBytes": "\(freedSnapshotBytes)",
                    ]
                )
            }
        } catch {
            self.log.warning(
                "ImagesService: snapshot sweep failed",
                metadata: [
                    "func": "\(function)",
                    "error": "\(error)",
                ]
            )
        }
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

        return try await imageStore.list().map { $0.description.fromCZ }
    }

    public func pull(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?, maxConcurrentDownloads: Int = 3) async throws
        -> ImageDescription
    {
        try await lock.withLock { _ in
            try await self._pull(
                reference: reference, platform: platform, insecure: insecure,
                progressUpdate: progressUpdate, maxConcurrentDownloads: maxConcurrentDownloads)
        }
    }

    private func _pull(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?, maxConcurrentDownloads: Int) async throws
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
        await self.sweepReplacedSnapshots()
        return img.description.fromCZ
    }

    public func push(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?) async throws {
        try await lock.withLock { _ in
            try await self._push(reference: reference, platform: platform, insecure: insecure, progressUpdate: progressUpdate)
        }
    }

    private func _push(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?) async throws {
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
        try await lock.withLock { _ in
            try await self._tag(old: old, new: new)
        }
    }

    private func _tag(old: String, new: String) async throws -> ImageDescription {
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

        let img = try await self.imageStore.tag(existing: old, new: new)
        return img.description.fromCZ
    }

    public func delete(reference: String, garbageCollect: Bool) async throws {
        try await lock.withLock { _ in
            try await self._delete(reference: reference, garbageCollect: garbageCollect)
        }
    }

    private func _delete(reference: String, garbageCollect: Bool) async throws {
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
        await self.sweepReplacedSnapshots()
    }

    public func save(references: [String], out: URL, platform: Platform?) async throws {
        try await lock.withLock { _ in
            try await self._save(references: references, out: out, platform: platform)
        }
    }

    private func _save(references: [String], out: URL, platform: Platform?) async throws {
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
        try await lock.withLock { _ in
            try await self._load(from: tarFile, force: force)
        }
    }

    private func _load(from tarFile: URL, force: Bool) async throws -> ([ImageDescription], [String]) {
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
        await self.sweepReplacedSnapshots()
        var images: [ImageDescription] = []
        for image in loaded {
            images.append(image.description.fromCZ)
        }
        return (images, rejectedMembers)
    }

    public func cleanUpOrphanedBlobs() async throws -> ([String], UInt64) {
        try await lock.withLock { _ in
            try await self._cleanUpOrphanedBlobs()
        }
    }

    private func _cleanUpOrphanedBlobs() async throws -> ([String], UInt64) {
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
            let imageDigest = image.digest.trimmingDigestPrefix
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
        try await lock.withLock { _ in
            try await self._unpack(description: description, platform: platform, progressUpdate: progressUpdate)
        }
    }

    private func _unpack(description: ImageDescription, platform: Platform?, progressUpdate: ProgressUpdateHandler?) async throws {
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
        try await lock.withLock { _ in
            try await self._deleteImageSnapshot(description: description, platform: platform)
        }
    }

    private func _deleteImageSnapshot(description: ImageDescription, platform: Platform?) async throws {
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
        try await lock.withLock { _ in
            try await self._getImageSnapshot(description: description, platform: platform)
        }
    }

    private func _getImageSnapshot(description: ImageDescription, platform: Platform) async throws -> Filesystem {
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
