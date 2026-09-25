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

import ContainerTestSupport
import Containerization
import ContainerizationArchive
import ContainerizationError
import CryptoKit
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct KernelServiceTests {
    @Test func installKernelFromLocalTarVerifiesDigest() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let digest = try KernelService.sha256Hex(of: tarFile)

            try await service.installKernelFrom(
                tar: URL(string: tarFile.path)!,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
        }
    }

    @Test func installKernelFromLocalTarRejectsDigestMismatchWithoutInstalling() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let wrongDigest = String(repeating: "0", count: 64)

            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: URL(fileURLWithPath: tarFile.path),
                    kernelFilePath: kernelPath,
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: "sha256:\(wrongDigest)",
                    force: false)
            }
            await #expect(throws: ContainerizationError.self) {
                _ = try await service.getDefaultKernel(platform: .linuxArm)
            }
        }
    }

    @Test func installKernelFromLocalTarRejectsInvalidDigestValues() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let sha256 = try KernelService.sha256Hex(of: tarFile)
            let sha1 = try Self.sha1Hex(of: tarFile)
            let invalidDigests = [
                "sha256-not-a-digest",
                "sha1:\(sha1)",
                "sha256:not-a-digest",
                String(repeating: "0", count: 64),
                "sha256:\(String(sha256.dropLast(2)))",
                "sha256:\(sha1)",
            ]

            for digest in invalidDigests {
                await #expect(throws: ContainerizationError.self) {
                    try await service.installKernelFrom(
                        tar: URL(fileURLWithPath: tarFile.path),
                        kernelFilePath: kernelPath,
                        platform: .linuxArm,
                        progressUpdate: nil,
                        expectedDigest: digest,
                        force: false)
                }
            }
            await #expect(throws: ContainerizationError.self) {
                _ = try await service.getDefaultKernel(platform: .linuxArm)
            }
        }
    }

    @Test func installKernelFromRemoteTarRequiresDigest() async throws {
        try await withTempDir { tempDir in
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))

            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: URL(string: "https://example.com/kernel.tar")!,
                    kernelFilePath: "boot/vmlinux",
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: nil,
                    force: false)
            }
        }
    }

    @Test func installKernelFromRemoteTarResumesInterruptedDownload() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data(repeating: 0x5a, count: 4096)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))

            let interruptedServer = try LoopbackFileServer(
                serving: archiveData,
                supportsRanges: true,
                disconnectAfterBytes: 512)
            defer { interruptedServer.shutdown() }
            await #expect(throws: (any Error).self) {
                try await service.installKernelFrom(
                    tar: interruptedServer.url,
                    kernelFilePath: kernelPath,
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: "sha256:\(digest)",
                    force: false)
            }
            interruptedServer.shutdown()

            let resumedServer = try LoopbackFileServer(serving: archiveData, supportsRanges: true)
            defer { resumedServer.shutdown() }
            try await service.installKernelFrom(
                tar: resumedServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            #expect(resumedServer.rangeHeaders == ["bytes=512-"])
            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
        }
    }

    @Test func installKernelFromRemoteTarUsesCompletePartialWithoutRequest() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let completePartial = appRoot.appendingPathComponent("downloads/kernels/\(digest).partial")
            try archiveData.write(to: completePartial)
            let unavailableServer = try LoopbackFileServer(serving: archiveData)
            defer { unavailableServer.shutdown() }
            let unavailableURL = unavailableServer.url
            unavailableServer.shutdown()

            try await service.installKernelFrom(
                tar: unavailableURL,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
        }
    }

    @Test func installKernelFromRemoteTarDiscardsDigestMismatch() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data(repeating: 0x5a, count: 4096)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            var corruptArchiveData = archiveData
            corruptArchiveData[corruptArchiveData.startIndex] ^= 0xff
            let digest = try KernelService.sha256Hex(of: tarFile)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))

            let corruptServer = try LoopbackFileServer(serving: corruptArchiveData)
            defer { corruptServer.shutdown() }
            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: corruptServer.url,
                    kernelFilePath: kernelPath,
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: "sha256:\(digest)",
                    force: false)
            }
            corruptServer.shutdown()

            let validServer = try LoopbackFileServer(serving: archiveData, supportsRanges: true)
            defer { validServer.shutdown() }
            try await service.installKernelFrom(
                tar: validServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            #expect(validServer.rangeHeaders.isEmpty)
            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
            let downloadDirectory = tempDir.appendingPathComponent("app/downloads/kernels")
            #expect(!FileManager.default.fileExists(atPath: downloadDirectory.appendingPathComponent("\(digest).partial").path))
            #expect(FileManager.default.fileExists(atPath: downloadDirectory.appendingPathComponent("\(digest).json").path))
        }
    }

    @Test func installKernelFromRemoteTarReusesVerifiedInstalledKernelWithoutRequest() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let firstService = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let server = try LoopbackFileServer(serving: archiveData)
            defer { server.shutdown() }

            try await firstService.installKernelFrom(
                tar: server.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)
            #expect(server.requestCount == 1)
            server.shutdown()

            let restartedService = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            try await restartedService.installKernelFrom(
                tar: server.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            let kernel = try await restartedService.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
        }
    }

    @Test func installKernelFromRemoteTarAcceptsIdenticalLegacyKernel() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let kernelDirectory = appRoot.appendingPathComponent("kernels")
            try FileManager.default.createDirectory(at: kernelDirectory, withIntermediateDirectories: true)
            try kernelData.write(to: kernelDirectory.appendingPathComponent("vmlinux"))
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let server = try LoopbackFileServer(serving: archiveData)
            defer { server.shutdown() }

            try await service.installKernelFrom(
                tar: server.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            #expect(server.requestCount == 1)
            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
        }
    }

    @Test func installKernelFromRemoteTarForceBypassesVerifiedKernel() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let firstServer = try LoopbackFileServer(serving: archiveData)
            defer { firstServer.shutdown() }

            try await service.installKernelFrom(
                tar: firstServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)
            firstServer.shutdown()

            let forcedServer = try LoopbackFileServer(serving: archiveData)
            defer { forcedServer.shutdown() }
            try await service.installKernelFrom(
                tar: forcedServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: true)

            #expect(forcedServer.requestCount == 1)
        }
    }

    @Test func installKernelFromRemoteTarRejectsModifiedInstalledKernelWithoutRequest() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let server = try LoopbackFileServer(serving: archiveData)
            defer { server.shutdown() }

            try await service.installKernelFrom(
                tar: server.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)
            server.shutdown()

            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            try Data("modified kernel".utf8).write(to: kernel.path)
            let unavailableServer = try LoopbackFileServer(serving: archiveData)
            defer { unavailableServer.shutdown() }
            let unavailableURL = unavailableServer.url
            unavailableServer.shutdown()

            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: unavailableURL,
                    kernelFilePath: kernelPath,
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: "sha256:\(digest)",
                    force: false)
            }
        }
    }

    @Test func installKernelFromRemoteTarRepairsCorruptMetadata() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let firstServer = try LoopbackFileServer(serving: archiveData)
            defer { firstServer.shutdown() }
            try await service.installKernelFrom(
                tar: firstServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)
            firstServer.shutdown()

            let metadataURL = appRoot.appendingPathComponent("downloads/kernels/\(digest).json")
            try Data("not json".utf8).write(to: metadataURL)
            let retryServer = try LoopbackFileServer(serving: archiveData)
            defer { retryServer.shutdown() }
            try await service.installKernelFrom(
                tar: retryServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            #expect(retryServer.requestCount == 1)
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
        }
    }

    @Test func installKernelFromRemoteTarRejectsMetadataPathTraversal() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let firstServer = try LoopbackFileServer(serving: archiveData)
            defer { firstServer.shutdown() }
            try await service.installKernelFrom(
                tar: firstServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)
            firstServer.shutdown()

            let metadataURL = appRoot.appendingPathComponent("downloads/kernels/\(digest).json")
            var metadata = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
            metadata["installedFileName"] = "../escape"
            try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

            let retryServer = try LoopbackFileServer(serving: archiveData)
            defer { retryServer.shutdown() }
            try await service.installKernelFrom(
                tar: retryServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            #expect(retryServer.requestCount == 1)
            #expect(!FileManager.default.fileExists(atPath: appRoot.appendingPathComponent("escape").path))
        }
    }

    @Test func installKernelFromRemoteTarReinstallsMissingRecordedKernel() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let archiveData = try Data(contentsOf: tarFile)
            let digest = try KernelService.sha256Hex(of: tarFile)
            let appRoot = tempDir.appendingPathComponent("app")
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: appRoot)
            let firstServer = try LoopbackFileServer(serving: archiveData)
            defer { firstServer.shutdown() }
            try await service.installKernelFrom(
                tar: firstServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)
            firstServer.shutdown()

            let installedKernel = try await service.getDefaultKernel(platform: .linuxArm)
            try FileManager.default.removeItem(at: installedKernel.path)
            let retryServer = try LoopbackFileServer(serving: archiveData)
            defer { retryServer.shutdown() }
            try await service.installKernelFrom(
                tar: retryServer.url,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            #expect(retryServer.requestCount == 1)
            let reinstalledKernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: reinstalledKernel.path) == kernelData)
        }
    }

    private static func writeTar(at tarFile: URL, path: String, data: Data) throws -> URL {
        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .none, file: tarFile)
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.size = numericCast(data.count)
        try archiver.writeEntry(entry: entry, data: data)
        try archiver.finishEncoding()
        return tarFile
    }

    private static func sha1Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withTempDir(body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
