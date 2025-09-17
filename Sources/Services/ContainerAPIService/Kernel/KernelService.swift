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
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import TerminalProgress

public actor KernelService {
    private static let defaultKernelNamePrefix: String = "default.kernel-"

    private let log: Logger
    private let kernelDirectory: URL

    public init(log: Logger, appRoot: URL) throws {
        self.log = log
        self.kernelDirectory = appRoot.appending(path: "kernels")
        try FileManager.default.createDirectory(at: self.kernelDirectory, withIntermediateDirectories: true)
    }

    /// Copies a kernel binary from a local path on disk into the managed kernels directory
    /// as the default kernel for the provided platform.
    public func installKernel(kernelFile url: URL, platform: SystemPlatform = .linuxArm, force: Bool) throws {
        self.log.info("KernelService: \(#function) - kernelFile: \(url), platform: \(String(describing: platform))")
        let kFile = url.resolvingSymlinksInPath()
        let destPath = self.kernelDirectory.appendingPathComponent(kFile.lastPathComponent)
        if force {
            do {
                try FileManager.default.removeItem(at: destPath)
            } catch let error as NSError {
                guard error.code == NSFileNoSuchFileError else {
                    throw error
                }
            }
        }
        try FileManager.default.copyItem(at: kFile, to: destPath)
        try Task.checkCancellation()
        do {
            try self.setDefaultKernel(name: kFile.lastPathComponent, platform: platform)
        } catch {
            try? FileManager.default.removeItem(at: destPath)
            throw error
        }
    }

    /// Copies a kernel binary from inside of tar file into the managed kernels directory
    /// as the default kernel for the provided platform.
    /// The parameter `tar` maybe a location to a local file on disk, or a remote URL.
    public func installKernelFrom(tar: URL, kernelFilePath: String, platform: SystemPlatform, progressUpdate: ProgressUpdateHandler?, force: Bool) async throws {
        self.log.info("KernelService: \(#function) - tar: \(tar), kernelFilePath: \(kernelFilePath), platform: \(String(describing: platform))")

        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        await progressUpdate?([
            .setDescription("Downloading kernel")
        ])
        let taskManager = ProgressTaskCoordinator()
        let downloadTask = await taskManager.startTask()
        var tarFile = tar
        if !FileManager.default.fileExists(atPath: tar.absoluteString) {
            self.log.debug("KernelService: Downloading \(tar)")
            tarFile = tempDir.appendingPathComponent(tar.lastPathComponent)
            var downloadProgressUpdate: ProgressUpdateHandler?
            if let progressUpdate {
                downloadProgressUpdate = ProgressTaskCoordinator.handler(for: downloadTask, from: progressUpdate)
            }
            try await ContainerClient.FileDownloader.downloadFile(url: tar, to: tarFile, progressUpdate: downloadProgressUpdate)
        }
        await taskManager.finish()

        await progressUpdate?([
            .setDescription("Unpacking kernel")
        ])
        let kernelFile = try self.extractFile(tarFile: tarFile, at: kernelFilePath, to: tempDir)
        try self.installKernel(kernelFile: kernelFile, platform: platform, force: force)

        if !FileManager.default.fileExists(atPath: tar.absoluteString) {
            try FileManager.default.removeItem(at: tarFile)
        }
    }

    private func setDefaultKernel(name: String, platform: SystemPlatform) throws {
        self.log.info("KernelService: \(#function) - name: \(name), platform: \(String(describing: platform))")
        let kernelPath = self.kernelDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            throw ContainerizationError(.notFound, message: "Kernel not found at \(kernelPath)")
        }
        let name = "\(Self.defaultKernelNamePrefix)\(platform.architecture)"
        let defaultKernelPath = self.kernelDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: defaultKernelPath)
        try FileManager.default.createSymbolicLink(at: defaultKernelPath, withDestinationURL: kernelPath)
    }

    public func getDefaultKernel(platform: SystemPlatform = .linuxArm) async throws -> Kernel {
        self.log.info("KernelService: \(#function) - platform: \(String(describing: platform))")
        let name = "\(Self.defaultKernelNamePrefix)\(platform.architecture)"
        let defaultKernelPath = self.kernelDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: defaultKernelPath.path) else {
            throw ContainerizationError(.notFound, message: "Default kernel not found at \(defaultKernelPath)")
        }
        return Kernel(path: defaultKernelPath, platform: platform)
    }

    private func extractFile(tarFile: URL, at: String, to directory: URL) throws -> URL {
        var target = at
        var archiveReader = try ArchiveReader(file: tarFile)
        var (entry, data) = try archiveReader.extractFile(path: target)

        // if the target file is a symlink, get the data for the actual file
        if entry.fileType == .symbolicLink, let symlinkRelative = entry.symlinkTarget {
            // the previous extractFile changes the underlying file pointer, so we need to reopen the file
            // to ensure we traverse all the files in the archive
            archiveReader = try ArchiveReader(file: tarFile)
            let symlinkTarget = URL(filePath: target).deletingLastPathComponent().appending(path: symlinkRelative)

            // standardize so that we remove any and all ../ and ./ in the path since symlink targets
            // are relative paths to the target file from the symlink's parent dir itself
            target = symlinkTarget.standardized.relativePath
            let (_, targetData) = try archiveReader.extractFile(path: target)
            data = targetData
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let fileName = URL(filePath: target).lastPathComponent
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
