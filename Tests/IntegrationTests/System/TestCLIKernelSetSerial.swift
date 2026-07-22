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

import ContainerPersistence
import ContainerTestSupport
import ContainerizationArchive
import Foundation
import Testing

/// Tests for `container system kernel set`. Each test modifies the global default
/// kernel binary, so the suite must run fully serialised.
///
/// None of these tests touch the network: they capture the bytes of whatever
/// kernel is already installed (from the previous test, or from the initial
/// `system start --enable-kernel-install`) and repackage them into a fixture
/// tar via ``KernelFixture``, so the real install/extract/digest-verify/
/// guest-boot code paths are still exercised end to end.
@Suite(.serialized)
struct TestCLIKernelSetSerial {
    private let fixture = KernelFixture()
    private let defaultBinaryPath = ContainerSystemConfig().kernel.binaryPath

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
        try await ContainerFixture.with { f in
            let capturedBinary = try prepareFixture(f)
            let tarPath = URL(filePath: f.testDir.string).appending(path: "kernel.tar")
            let digest = try fixture.writeTar(binary: capturedBinary, binaryArchivePath: defaultBinaryPath, to: tarPath)

            try f.run([
                "system", "kernel", "set",
                "--force",
                "--tar", tarPath.path,
                "--binary", symlinkBinaryPath,
                "--digest", digest,
            ]).check()
            try await validateGuestKernel(f)
        }
    }

    @Test func fromRemoteTarSymlink() async throws {
        try await ContainerFixture.with { f in
            let capturedBinary = try prepareFixture(f)
            let tarPath = URL(filePath: f.testDir.string).appending(path: "kernel.tar")
            let digest = try fixture.writeTar(binary: capturedBinary, binaryArchivePath: defaultBinaryPath, to: tarPath)

            let server = try LoopbackFileServer(serving: try Data(contentsOf: tarPath))
            defer { server.shutdown() }

            try f.run([
                "system", "kernel", "set",
                "--force",
                "--tar", server.url.absoluteString,
                "--binary", symlinkBinaryPath,
                "--digest", digest,
            ]).check()
            try await validateGuestKernel(f)
        }
    }

    @Test func fromLocalDisk() async throws {
        try await ContainerFixture.with { f in
            let capturedBinary = try prepareFixture(f)
            try f.run(["system", "kernel", "set", "--force", "--binary", capturedBinary.path]).check()
            try await validateGuestKernel(f)
        }
    }

    // MARK: - Private helpers

    /// The archive path `fromLocalTar`/`fromRemoteTarSymlink` request — a symlink
    /// alongside the real binary, deliberately exercising `KernelService.extractFile`'s
    /// symlink-following branch.
    private var symlinkBinaryPath: String {
        URL(filePath: defaultBinaryPath)
            .deletingLastPathComponent()
            .appending(path: "vmlinux.container")
            .relativePath
    }

    /// Captures the currently-installed kernel binary and registers cleanup to
    /// restore it regardless of test outcome. The upcoming `kernel set --force`
    /// command overwrites whatever is currently installed, so there's no need
    /// to clear it out first.
    private func prepareFixture(_ f: ContainerFixture) throws -> URL {
        let capturedBinary = URL(filePath: f.testDir.string).appending(path: "captured-kernel")
        try fixture.captureInstalledBinary(to: capturedBinary)
        f.addCleanup { Self.restoreCapturedKernel(f, from: capturedBinary) }
        return capturedBinary
    }

    /// Restores the kernel captured at the start of a test. Used as cleanup at the
    /// end of every test so a failure here doesn't silently affect the next test —
    /// the suite is serialised and the kernel is global state. The fixture's
    /// cleanup runner swallows throws with `try?`, so we record an issue against
    /// the current test rather than rely on error propagation.
    private static func restoreCapturedKernel(_ f: ContainerFixture, from capturedBinary: URL) {
        do {
            let result = try f.run(["system", "kernel", "set", "--force", "--binary", capturedBinary.path])
            if result.status != 0 {
                Issue.record("kernel restore from captured binary failed (status \(result.status)): \(result.error)")
            }
        } catch {
            Issue.record("kernel restore from captured binary could not run: \(error)")
        }
    }

    /// Boots a container and verifies that the guest is running the kernel just set
    /// on the host — that is, `uname -r` matches the release parsed from the kernel
    /// binary filename (see ``expectedKernelRelease``).
    private func validateGuestKernel(_ f: ContainerFixture) async throws {
        let image = WarmupImage.alpine320.rawValue
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
