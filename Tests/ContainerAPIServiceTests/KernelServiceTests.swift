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

import Containerization
import ContainerizationArchive
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct KernelServiceTests {
    @Test func verifyDigest() throws {
        try withTempFile(contents: "kernel archive") { file in
            try KernelService.verifyDigest(of: file, expected: "sha256:\(KernelService.sha256Hex(of: file))")
            #expect(throws: ContainerizationError.self) {
                try KernelService.verifyDigest(of: file, expected: "sha256-not-a-digest")
            }
            #expect(throws: ContainerizationError.self) {
                try KernelService.verifyDigest(of: file, expected: "sha256:not-a-digest")
            }
            #expect(throws: ContainerizationError.self) {
                try KernelService.verifyDigest(of: file, expected: String(repeating: "0", count: 64))
            }
            #expect(throws: ContainerizationError.self) {
                try KernelService.verifyDigest(of: file, expected: "sha256:\(String(repeating: "0", count: 64))")
            }
        }
    }

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

    private func withTempFile(contents: String, body: (URL) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try body(file)
    }

    private func withTempDir(body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}
