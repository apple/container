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
import ContainerPersistence
import ContainerizationArchive
import Foundation
import Testing

/// Tests for `container system kernel set`. Each test modifies the global default
/// kernel binary, so the suite must run fully serialised.
@Suite(.serialized)
struct TestCLIKernelSetSerial {
    private let remoteTar = ContainerSystemConfig().kernel.url
    private let defaultBinaryPath = ContainerSystemConfig().kernel.binaryPath

    // MARK: - Tests

    @Test func fromLocalTar() async throws {
        let symlinkBinaryPath = URL(filePath: defaultBinaryPath)
            .deletingLastPathComponent()
            .appending(path: "vmlinux.container")
            .relativePath

        try await ContainerFixture.with { f in
            f.addCleanup { _ = try? f.run(["system", "kernel", "set", "--recommended", "--force"]) }
            try await f.withTempDir { tempDir in
                let localTarPath = tempDir.appending(path: remoteTar.lastPathComponent)
                try await ContainerAPIClient.FileDownloader.downloadFile(url: remoteTar, to: localTarPath)
                try f.run(["system", "kernel", "set", "--force", "--tar", localTarPath.path, "--binary", symlinkBinaryPath]).check()
                try await validateContainerRun(f)
            }
        }
    }

    @Test func fromRemoteTarSymlink() async throws {
        let symlinkBinaryPath = URL(filePath: defaultBinaryPath)
            .deletingLastPathComponent()
            .appending(path: "vmlinux.container")
            .relativePath

        try await ContainerFixture.with { f in
            f.addCleanup { _ = try? f.run(["system", "kernel", "set", "--recommended", "--force"]) }
            try f.run(["system", "kernel", "set", "--force", "--tar", remoteTar.absoluteString, "--binary", symlinkBinaryPath]).check()
            try await validateContainerRun(f)
        }
    }

    @Test func fromLocalDisk() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { _ = try? f.run(["system", "kernel", "set", "--recommended", "--force"]) }
            try await f.withTempDir { tempDir in
                let localTarPath = tempDir.appending(path: remoteTar.lastPathComponent)
                try await ContainerAPIClient.FileDownloader.downloadFile(url: remoteTar, to: localTarPath)

                let targetPath = tempDir.appending(path: URL(string: defaultBinaryPath)!.lastPathComponent)
                let archiveReader = try ArchiveReader(file: localTarPath)
                let (_, data) = try archiveReader.extractFile(path: defaultBinaryPath)
                try data.write(to: targetPath, options: .atomic)

                try f.run(["system", "kernel", "set", "--force", "--binary", targetPath.path]).check()
                try await validateContainerRun(f)
            }
        }
    }

    // MARK: - Private helpers

    private func validateContainerRun(_ f: ContainerFixture) async throws {
        let image = try f.copyWarmupImage(ContainerFixture.warmupImages[0])
        try await f.withContainer(image: image) { name in
            _ = try f.doExec(name, cmd: ["date"])
        }
    }
}
