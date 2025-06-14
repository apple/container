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

import ContainerClient
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import TerminalProgress

public actor SnapshotStore {
    private static let snapshotFileName = "snapshot"
    private static let snapshotInfoFileName = "snapshot-info"
    private static let ingestDirName = "ingest"

    let path: URL
    let fm = FileManager.default
    let ingestDir: URL

    public init(path: URL) throws {
        let root = path.appendingPathComponent("snapshots")
        self.path = root
        self.ingestDir = self.path.appendingPathComponent(Self.ingestDirName)
        try self.fm.createDirectory(at: root, withIntermediateDirectories: true)
        try self.fm.createDirectory(at: self.ingestDir, withIntermediateDirectories: true)
    }

    public func unpack(image: Containerization.Image, platform: Platform? = nil, progressUpdate: ProgressUpdateHandler?) async throws {
        var toUnpack: [Descriptor] = []
        if let platform {
            let desc = try await image.descriptor(for: platform)
            toUnpack = [desc]
        } else {
            toUnpack = try await image.unpackableDescriptors()
        }

        let taskManager = ProgressTaskCoordinator()
        var taskUpdateProgress: ProgressUpdateHandler?

        for desc in toUnpack {
            try Task.checkCancellation()
            let snapshotDir = self.snapshotDir(desc)
            guard !self.fm.fileExists(atPath: snapshotDir.absolutePath()) else {
                // We have already unpacked this image + platform. Skip
                continue
            }
            guard let platform = desc.platform else {
                throw ContainerizationError(.internalError, message: "Missing platform for descriptor \(desc.digest)")
            }
            guard Self.shouldUnpackPlatform(platform) else {
                continue
            }
            let currentSubTask = await taskManager.startTask()
            if let progressUpdate {
                let _taskUpdateProgress = ProgressTaskCoordinator.handler(for: currentSubTask, from: progressUpdate)
                await _taskUpdateProgress([
                    .setSubDescription("for platform \(platform.description)")
                ])
                taskUpdateProgress = _taskUpdateProgress
            }

            let tempDir = try self.tempUnpackDir()

            let tempSnapshotPath = tempDir.appendingPathComponent(Self.snapshotFileName, isDirectory: false)
            let infoPath = tempDir.appendingPathComponent(Self.snapshotInfoFileName, isDirectory: false)
            do {
                let mount = try await image.unpack(for: platform, at: tempSnapshotPath, progress: ContainerizationProgressAdapter.handler(from: taskUpdateProgress))
                let fs = Filesystem.block(
                    format: mount.type,
                    source: self.snapshotPath(desc).absolutePath(),
                    destination: mount.destination,
                    options: mount.options
                )
                let snapshotInfo = try JSONEncoder().encode(fs)
                self.fm.createFile(atPath: infoPath.absolutePath(), contents: snapshotInfo)
            } catch {
                try? self.fm.removeItem(at: tempDir)
                throw error
            }
            do {
                try fm.moveItem(at: tempDir, to: snapshotDir)
            } catch let err as NSError {
                guard err.code == NSFileWriteFileExistsError else {
                    throw err
                }
                try? self.fm.removeItem(at: tempDir)
            }
        }
        await taskManager.finish()
    }

    public func delete(for image: Containerization.Image, platform: Platform? = nil) async throws {
        var toDelete: [Descriptor] = []
        if let platform {
            let desc = try await image.descriptor(for: platform)
            toDelete.append(desc)
        } else {
            toDelete = try await image.unpackableDescriptors()
        }
        for desc in toDelete {
            let p = self.snapshotDir(desc)
            guard self.fm.fileExists(atPath: p.absolutePath()) else {
                continue
            }
            try self.fm.removeItem(at: p)
        }
    }

    public func get(for image: Containerization.Image, platform: Platform) async throws -> Filesystem {
        let desc = try await image.descriptor(for: platform)
        let infoPath = snapshotInfoPath(desc)
        let fsPath = snapshotPath(desc)

        guard self.fm.fileExists(atPath: infoPath.absolutePath()),
            self.fm.fileExists(atPath: fsPath.absolutePath())
        else {
            throw ContainerizationError(.notFound, message: "image snapshot for \(image.reference) with platform \(platform.description)")
        }
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: infoPath)
        let fs = try decoder.decode(Filesystem.self, from: data)
        return fs
    }

    public func clean(keepingSnapshotsFor images: [Containerization.Image] = []) async throws -> UInt64 {
        var toKeep: [String] = [Self.ingestDirName]
        for image in images {
            for manifest in try await image.index().manifests {
                guard let platform = manifest.platform else {
                    continue
                }
                let desc = try await image.descriptor(for: platform)
                toKeep.append(desc.digest.trimmingDigestPrefix)
            }
        }
        let all = try self.fm.contentsOfDirectory(at: self.path, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]).map {
            $0.lastPathComponent
        }
        let delete = Set(all).subtracting(Set(toKeep))
        var deletedBytes: UInt64 = 0
        for dir in delete {
            let unpackedPath = self.path.appending(path: dir, directoryHint: .isDirectory)
            guard self.fm.fileExists(atPath: unpackedPath.absolutePath()) else {
                continue
            }
            deletedBytes += (try? self.fm.directorySize(dir: unpackedPath)) ?? 0
            try self.fm.removeItem(at: unpackedPath)
        }
        return deletedBytes
    }

    private func snapshotDir(_ desc: Descriptor) -> URL {
        let p = self.path.appendingPathComponent(desc.digest.trimmingDigestPrefix, isDirectory: true)
        return p
    }

    private func snapshotPath(_ desc: Descriptor) -> URL {
        let p = self.snapshotDir(desc)
            .appendingPathComponent(Self.snapshotFileName, isDirectory: false)
        return p
    }

    private func snapshotInfoPath(_ desc: Descriptor) -> URL {
        let p = self.snapshotDir(desc)
            .appendingPathComponent(Self.snapshotInfoFileName, isDirectory: false)
        return p
    }

    private func tempUnpackDir() throws -> URL {
        let uniqueDirectoryURL = ingestDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try self.fm.createDirectory(at: uniqueDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        return uniqueDirectoryURL
    }

    private static func shouldUnpackPlatform(_ platform: Platform) -> Bool {
        guard platform.os == "linux" else {
            return false
        }
        return true
    }
}

extension FileManager {
    fileprivate func directorySize(dir: URL) throws -> UInt64 {
        var size = 0
        let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let contents = try self.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: resourceKeys)

        for p in contents {
            let val = try p.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            size += val.totalFileAllocatedSize ?? val.fileAllocatedSize ?? 0
        }
        return UInt64(size)
    }
}

extension Containerization.Image {
    fileprivate func unpackableDescriptors() async throws -> [Descriptor] {
        let index = try await self.index()
        return index.manifests.filter { desc in
            guard desc.platform != nil else {
                return false
            }
            if let referenceType = desc.annotations?["vnd.docker.reference.type"], referenceType == "attestation-manifest" {
                return false
            }
            return true
        }
    }
}
