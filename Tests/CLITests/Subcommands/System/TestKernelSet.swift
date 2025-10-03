//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import ContainerPersistence
import ContainerizationArchive
import Foundation
import Testing

// This suite is run serialized since each test modifies the global default kernel
@Suite(.serialized)
class TestCLIKernelSet: CLITest {
    let defaultKernelTar = DefaultsStore.get(key: .defaultKernelURL)
    var remoteTar: URL! {
        URL(string: defaultKernelTar)
    }
    let defaultBinaryPath = DefaultsStore.get(key: .defaultKernelBinaryPath)

    deinit {
        try? resetDefaultBinary()
    }

    func resetDefaultBinary() throws {
        let arguments: [String] = [
            "system",
            "kernel",
            "set",
            "--recommended",
            "--force",
        ]
        let (_, error, status) = try run(arguments: arguments)
        if status != 0 {
            throw CLIError.executionFailed("failed to reset kernel to recommended: \(error)")
        }
    }

    func doKernelSet(extraArgs: [String]) throws {
        var arguments = [
            "system",
            "kernel",
            "set",
            "--force",
        ]
        arguments.append(contentsOf: extraArgs)

        let (_, error, status) = try run(arguments: arguments)
        if status != 0 {
            throw CLIError.executionFailed("failed to set kernel: \(error)")
        }
    }

    func validateContainerRun() throws {
        let name = getTestName()
        try doLongRun(name: name, args: [])
        defer { try? doStop(name: name) }

        _ = try doExec(name: name, cmd: ["date"])
        try doStop(name: name)
    }

    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    @Test func fromLocalTar() async throws {
        let symlinkBinaryPath: String = URL(filePath: defaultBinaryPath).deletingLastPathComponent().appending(path: "vmlinux.container").relativePath

        try await withTempDir { tempDir in
            // manually download the tar file
            let localTarPath = tempDir.appending(path: remoteTar.lastPathComponent)
            try await ContainerClient.FileDownloader.downloadFile(url: remoteTar, to: localTarPath)

            let extraArgs: [String] = [
                "--tar",
                localTarPath.path,
                "--binary",
                symlinkBinaryPath,
            ]

            try doKernelSet(extraArgs: extraArgs)
            try validateContainerRun()
        }
    }

    @Test func fromRemoteTarSymlink() throws {
        // opt/kata/share/kata-containers/vmlinux.container should point to opt/kata/share/kata-containers/vmlinux-<version> in the archive
        let symlinkBinaryPath: String = URL(filePath: defaultBinaryPath).deletingLastPathComponent().appending(path: "vmlinux.container").relativePath
        let extraArgs: [String] = [
            "--tar",
            defaultKernelTar,
            "--binary",
            symlinkBinaryPath,
        ]

        try doKernelSet(extraArgs: extraArgs)
        try validateContainerRun()
    }

    @Test func fromLocalDisk() async throws {
        try await withTempDir { tempDir in
            // manually download the tar file
            let localTarPath = tempDir.appending(path: remoteTar.lastPathComponent)
            try await ContainerClient.FileDownloader.downloadFile(url: remoteTar, to: localTarPath)

            // extract just the file we want
            let targetPath = tempDir.appending(path: URL(string: defaultBinaryPath)!.lastPathComponent)
            let archiveReader = try ArchiveReader(file: localTarPath)
            let (_, data) = try archiveReader.extractFile(path: defaultBinaryPath)
            try data.write(to: targetPath, options: .atomic)

            let extraArgs = [
                "--binary",
                targetPath.path,
            ]
            try doKernelSet(extraArgs: extraArgs)
            try validateContainerRun()
        }
    }
}
