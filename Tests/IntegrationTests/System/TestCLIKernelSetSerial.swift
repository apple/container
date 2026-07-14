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
    private let defaultDigest = KernelConfig.defaultDigest

    /// Kernel release string parsed from the binary filename.
    ///
    /// The binary path is conventionally `vmlinux-{release}` — but Kata's distribution
    /// appends a `-{buildNumber}` suffix to the file (e.g. `vmlinux-6.18.15-186`)
    /// while `uname -r` in the guest only reports the upstream release (`6.18.15`).
    /// We strip a trailing `-N` where N is all digits to match what the guest reports,
    /// while preserving non-numeric suffixes like `-rc1` or `-rt` that ARE part of the
    /// upstream release string.
    private var expectedKernelRelease: String {
        let filename = URL(fileURLWithPath: defaultBinaryPath).lastPathComponent
        let prefix = "vmlinux-"
        let raw = filename.hasPrefix(prefix) ? String(filename.dropFirst(prefix.count)) : filename
        if let dashIdx = raw.lastIndex(of: "-"),
            raw[raw.index(after: dashIdx)...].allSatisfy({ $0.isNumber })
        {
            return String(raw[..<dashIdx])
        }
        return raw
    }

    // MARK: - Tests

    @Test func remoteTarCannotBeShadowedByLocalPath() async throws {
        try await ContainerFixture.with { f in
            let shadow = URL(filePath: f.testDir.string)
                .appending(path: "https:")
                .appending(path: "example.com")
                .appending(path: "kernel.tar")
            try FileManager.default.createDirectory(
                at: shadow.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data().write(to: shadow)

            let result = try f.run(
                [
                    "system", "kernel", "set",
                    "--tar", "https://example.com/kernel.tar",
                    "--binary", "vmlinux",
                ],
                currentDirectory: f.testDir)

            #expect(result.status != 0)
            #expect(result.error.contains("'--digest' is required when '--tar' is a remote URL"))
        }
    }

    @Test func fromLocalTar() async throws {
        let symlinkBinaryPath = URL(filePath: defaultBinaryPath)
            .deletingLastPathComponent()
            .appending(path: "vmlinux.container")
            .relativePath

        try await ContainerFixture.with { f in
            f.addCleanup { resetKernelToRecommended(f) }
            let tempDir = URL(filePath: f.testDir.string)
            let localTarPath = tempDir.appending(path: remoteTar.lastPathComponent)
            try await ContainerAPIClient.FileDownloader.downloadFile(url: remoteTar, to: localTarPath)
            try f.run([
                "system", "kernel", "set",
                "--force",
                "--tar", localTarPath.path,
                "--binary", symlinkBinaryPath,
                "--digest", defaultDigest,
            ]).check()
            try await validateGuestKernel(f)
        }
    }

    @Test func fromRemoteTarSymlink() async throws {
        let symlinkBinaryPath = URL(filePath: defaultBinaryPath)
            .deletingLastPathComponent()
            .appending(path: "vmlinux.container")
            .relativePath

        try await ContainerFixture.with { f in
            f.addCleanup { resetKernelToRecommended(f) }
            try f.run([
                "system", "kernel", "set",
                "--force",
                "--tar", remoteTar.absoluteString,
                "--binary", symlinkBinaryPath,
                "--digest", defaultDigest,
            ]).check()
            try await validateGuestKernel(f)
        }
    }

    @Test func fromLocalDisk() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { resetKernelToRecommended(f) }
            let tempDir = URL(filePath: f.testDir.string)
            let localTarPath = tempDir.appending(path: remoteTar.lastPathComponent)
            try await ContainerAPIClient.FileDownloader.downloadFile(url: remoteTar, to: localTarPath)

            let targetPath = tempDir.appending(path: URL(string: defaultBinaryPath)!.lastPathComponent)
            let archiveReader = try ArchiveReader(file: localTarPath)
            let (_, data) = try archiveReader.extractFile(path: defaultBinaryPath)
            try data.write(to: targetPath, options: .atomic)

            try f.run(["system", "kernel", "set", "--force", "--binary", targetPath.path]).check()
            try await validateGuestKernel(f)
        }
    }

    // MARK: - Private helpers

    /// Resets the kernel back to the recommended default. Used as a cleanup at the
    /// end of every test so a failure here doesn't silently affect the next test —
    /// the suite is serialised and the kernel is global state. The fixture's
    /// cleanup runner swallows throws with `try?`, so we record an issue against
    /// the current test rather than rely on error propagation.
    private func resetKernelToRecommended(_ f: ContainerFixture) {
        do {
            let result = try f.run(["system", "kernel", "set", "--recommended", "--force"])
            if result.status != 0 {
                Issue.record("kernel reset to --recommended failed (status \(result.status)): \(result.error)")
            }
        } catch {
            Issue.record("kernel reset to --recommended could not run: \(error)")
        }
    }

    /// Boots a container and verifies that the guest is running the kernel just set
    /// on the host — that is, `uname -r` matches the release parsed from the kernel
    /// binary filename (see ``expectedKernelRelease``).
    private func validateGuestKernel(_ f: ContainerFixture) async throws {
        let image = ContainerFixture.warmupImages[0]
        if try !f.isImagePresent(image) { try f.doPull(image) }
        try await f.withContainer(image: image) { name in
            let release = try f.doExec(name, cmd: ["uname", "-r"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                release == expectedKernelRelease,
                "expected guest kernel \(expectedKernelRelease), got \(release)")
        }
    }
}
