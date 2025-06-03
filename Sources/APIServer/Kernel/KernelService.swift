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

actor KernelService {
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
    public func installKernel(kernelFile url: URL, platform: SystemPlatform = .linuxArm) throws {
        self.log.info("KernelService: \(#function) - kernelFile: \(url), platform: \(String(describing: platform))")
        let kFile = url.resolvingSymlinksInPath()
        let destPath = self.kernelDirectory.appendingPathComponent(kFile.lastPathComponent)
        try FileManager.default.copyItem(at: kFile, to: destPath)
        try self.setDefaultKernel(name: kFile.lastPathComponent, platform: platform)
    }

    /// Copies a kernel binary from inside of tar file into the managed kernels directory
    /// as the default kernel for the provided platform.
    /// The parameter `tar` maybe a location to a local file on disk, or a remote URL.
    public func installKernelFrom(tar: URL, kernelFilePath: String, platform: SystemPlatform, progressUpdate: ProgressUpdateHandler?) async throws {
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
            try await FileDownloader.downloadFile(url: tar, to: tarFile, progressUpdate: downloadProgressUpdate)
        }
        await taskManager.finish()

        await progressUpdate?([
            .setDescription("Unpacking kernel")
        ])
        let archiveReader = try ArchiveReader(file: tarFile)
        try archiveReader.extractContents(to: tempDir)
        let kernelPath = tempDir.appendingPathComponent(kernelFilePath).resolvingSymlinksInPath()
        try self.installKernel(kernelFile: kernelPath, platform: platform)

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
}
