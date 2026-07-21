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

import ContainerPlugin
import Containerization
import ContainerizationArchive
import CryptoKit
import Foundation

/// Fixture helpers for `TestCLIKernelSetSerial`.
///
/// `container system kernel set` always requires a kernel to already be
/// installed for the integration suite to run at all (`system start
/// --enable-kernel-install` guarantees this). Rather than downloading the real
/// ~570MB kata-static release tarball in every test, these helpers capture the
/// bytes of whatever kernel is already installed and repackage them into a
/// tar with the same internal layout (a real binary plus the `vmlinux.container`
/// symlink member kata's release tarballs ship) so the real install/extract/
/// digest-verify code paths still get exercised, without any network access.
struct KernelFixture {
    private let kernelsDirectory = URL(fileURLWithPath: ApplicationRoot.pathname).appendingPathComponent("kernels")

    private var defaultKernelSymlink: URL {
        kernelsDirectory.appendingPathComponent("default.kernel-\(SystemPlatform.linuxArm.architecture.rawValue)")
    }

    /// Copies the bytes of the currently-installed default kernel to `destination`.
    func captureInstalledBinary(to destination: URL) throws {
        let resolved = defaultKernelSymlink.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw CommandError.executionFailed("no default kernel installed at \(resolved.path)")
        }
        try FileManager.default.copyItem(at: resolved, to: destination)
    }

    /// Writes a tar at `tarPath` containing `binary`'s bytes at `binaryArchivePath`,
    /// plus a `vmlinux.container` symlink alongside it pointing at the binary's
    /// filename — mirroring the layout `KernelService.extractFile`'s
    /// symlink-following branch expects.
    ///
    /// Returns the tar's own `sha256:<hex>` digest, since `container system
    /// kernel set --digest` verifies the archive's digest, not the extracted
    /// binary's.
    @discardableResult
    func writeTar(binary: URL, binaryArchivePath: String, to tarPath: URL) throws -> String {
        let binaryData = try Data(contentsOf: binary)

        let writer = try ArchiveWriter(format: .ustar, filter: .none, file: tarPath)
        let fileEntry = WriteEntry()
        fileEntry.path = binaryArchivePath
        fileEntry.fileType = .regular
        fileEntry.permissions = 0o644
        fileEntry.size = Int64(binaryData.count)
        try writer.writeEntry(entry: fileEntry, data: binaryData)

        let symlinkEntry = WriteEntry()
        symlinkEntry.path =
            URL(filePath: binaryArchivePath)
            .deletingLastPathComponent()
            .appending(path: "vmlinux.container")
            .relativePath
        symlinkEntry.fileType = .symbolicLink
        symlinkEntry.symlinkTarget = URL(filePath: binaryArchivePath).lastPathComponent
        symlinkEntry.permissions = 0o644
        try writer.writeEntry(entry: symlinkEntry, data: nil)

        try writer.finishEncoding()

        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: tarPath)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}
