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
import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import CryptoKit
import Foundation
import Logging
import TerminalProgress

public actor KernelService {
    private static let defaultKernelNamePrefix: String = "default.kernel-"

    private let log: Logger
    private let kernelDirectory: URL

    private struct ExpectedDigest {
        let algorithm: String
        let hex: String
    }

    public init(log: Logger, appRoot: URL) throws {
        self.log = log
        self.kernelDirectory = appRoot.appending(path: "kernels")
        try FileManager.default.createDirectory(at: self.kernelDirectory, withIntermediateDirectories: true)
    }

    /// Copies a kernel binary from a local path on disk into the managed kernels directory
    /// as the default kernel for the provided platform.
    public func installKernel(kernelFile url: URL, platform: SystemPlatform = .linuxArm, force: Bool) throws {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "kernelFile": "\(url)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "kernelFile": "\(url)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

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
    public func installKernelFrom(
        tar: URL,
        kernelFilePath: String,
        platform: SystemPlatform,
        progressUpdate: ProgressUpdateHandler?,
        expectedDigest: String? = nil,
        force: Bool
    ) async throws {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "tar": "\(tar)",
                "kernelFilePath": "\(kernelFilePath)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "tar": "\(tar)",
                    "kernelFilePath": "\(kernelFilePath)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        var tarFile = tar
        let localTarPath = tar.scheme == nil || tar.isFileURL ? tar.path : nil
        let isLocalTar = localTarPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        if isLocalTar, let localTarPath {
            tarFile = URL(fileURLWithPath: localTarPath)
        }
        guard isLocalTar || expectedDigest != nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel archive digest is required for remote URL '\(tar)'"
            )
        }
        let expectedDigest = try expectedDigest.map(Self.parseExpectedDigest)

        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        await progressUpdate?([
            .setDescription(isLocalTar ? "Reading kernel archive" : "Downloading kernel")
        ])
        var downloadedSHA256Digest: String?
        if !isLocalTar {
            let taskManager = ProgressTaskCoordinator()
            let downloadTask = await taskManager.startTask()
            self.log.debug("KernelService: start download", metadata: ["tar": "\(tar)"])
            tarFile = tempDir.appendingPathComponent(tar.lastPathComponent)
            var downloadProgressUpdate: ProgressUpdateHandler?
            if let progressUpdate {
                downloadProgressUpdate = ProgressTaskCoordinator.handler(for: downloadTask, from: progressUpdate)
            }
            downloadedSHA256Digest = try await ContainerAPIClient.FileDownloader.downloadFile(
                url: tar,
                to: tarFile,
                progressUpdate: downloadProgressUpdate,
                computingSHA256: expectedDigest != nil)
            await taskManager.finish()
        }
        await progressUpdate?([
            .addTasks(1)
        ])

        if let expectedDigest {
            await progressUpdate?([
                .setDescription("Verifying kernel archive")
            ])
            if let downloadedSHA256Digest {
                try Self.verifyDigest(actualSHA256Hex: downloadedSHA256Digest, expected: expectedDigest)
            } else {
                try Self.verifyDigest(of: tarFile, expected: expectedDigest)
            }
            await progressUpdate?([
                .addTasks(1)
            ])
        }

        await progressUpdate?([
            .setDescription("Unpacking kernel")
        ])
        let kernelFile = try self.extractFile(tarFile: tarFile, at: kernelFilePath, to: tempDir)
        try self.installKernel(kernelFile: kernelFile, platform: platform, force: force)
        await progressUpdate?([
            .addTasks(1)
        ])

        if !isLocalTar {
            try FileManager.default.removeItem(at: tarFile)
        }
    }

    private static func verifyDigest(of file: URL, expected: ExpectedDigest) throws {
        let actualDigest = try sha256Hex(of: file)
        try verifyDigest(actualSHA256Hex: actualDigest, expected: expected)
    }

    private static func verifyDigest(actualSHA256Hex actualDigest: String, expected: ExpectedDigest) throws {
        guard actualDigest == expected.hex else {
            throw ContainerizationError(
                .invalidState,
                message: "kernel archive digest mismatch: expected sha256:\(expected.hex), got sha256:\(actualDigest)"
            )
        }
    }

    private static func parseExpectedDigest(_ expected: String) throws -> ExpectedDigest {
        let parts = expected.lowercased().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "invalid digest value '\(expected)': expected '<algorithm>:<hex>'")
        }
        let digest = ExpectedDigest(algorithm: String(parts[0]), hex: String(parts[1]))
        guard digest.algorithm == "sha256" else {
            throw ContainerizationError(.unsupported, message: "unsupported digest algorithm '\(digest.algorithm)'")
        }
        guard digest.hex.count == 64, digest.hex.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw ContainerizationError(.invalidArgument, message: "invalid sha256 digest value '\(expected)'")
        }
        return digest
    }

    static func sha256Hex(of file: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: Int(1.mib())), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func setDefaultKernel(name: String, platform: SystemPlatform) throws {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "name": "\(name)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "name": "\(name)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let kernelPath = self.kernelDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            throw ContainerizationError(.notFound, message: "kernel not found at \(kernelPath)")
        }
        let name = "\(Self.defaultKernelNamePrefix)\(platform.architecture)"
        let defaultKernelPath = self.kernelDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: defaultKernelPath)
        try FileManager.default.createSymbolicLink(at: defaultKernelPath, withDestinationURL: kernelPath)
    }

    public func getDefaultKernel(platform: SystemPlatform = .linuxArm) async throws -> Kernel {
        log.debug(
            "KernelService: enter",
            metadata: [
                "func": "\(#function)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            log.debug(
                "KernelService: exit",
                metadata: [
                    "func": "\(#function)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let name = "\(Self.defaultKernelNamePrefix)\(platform.architecture)"
        let defaultKernelPath = self.kernelDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: defaultKernelPath.path) else {
            throw ContainerizationError(.notFound, message: "default kernel not found at \(defaultKernelPath)")
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
