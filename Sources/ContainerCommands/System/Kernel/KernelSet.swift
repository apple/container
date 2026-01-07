//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

extension Application {
    public struct KernelSet: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the default kernel"
        )

        @Option(name: .long, help: "The architecture of the kernel binary (values: amd64, arm64)")
        var arch: String = ContainerizationOCI.Platform.current.architecture.description

        @Option(name: .customLong("binary"), help: "Path to the kernel file (or archive member, if used with --tar)")
        var binaryPath: String? = nil

        @Flag(name: .long, help: "Overwrites an existing kernel with the same name")
        var force: Bool = false

        @Flag(name: .long, help: "Download and install the recommended kernel as the default (takes precedence over all other flags)")
        var recommended: Bool = false

        @Option(name: .customLong("tar"), help: "Filesystem path or remote URL to a tar archive containing a kernel file")
        var tarPath: String? = nil

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            if recommended {
                let url = DefaultsStore.get(key: .defaultKernelURL)
                let path = DefaultsStore.get(key: .defaultKernelBinaryPath)
                print("Installing the recommended kernel from \(url)...")
                try await Self.downloadAndInstallWithProgressBar(tarRemoteURL: url, kernelFilePath: path, force: force)
                return
            }
            guard tarPath != nil else {
                return try await self.setKernelFromBinary()
            }
            try await self.setKernelFromTar()
        }

        private func setKernelFromBinary() async throws {
            guard let binaryPath else {
                throw ArgumentParser.ValidationError("missing argument '--binary'")
            }
            let absolutePath = URL(fileURLWithPath: binaryPath, relativeTo: .currentDirectory()).absoluteURL.absoluteString
            let platform = try getSystemPlatform()
            try await ClientKernel.installKernel(kernelFilePath: absolutePath, platform: platform, force: force)
        }

        private func setKernelFromTar() async throws {
            guard let binaryPath else {
                throw ArgumentParser.ValidationError("missing argument '--binary'")
            }
            guard let tarPath else {
                throw ArgumentParser.ValidationError("missing argument '--tar")
            }
            let platform = try getSystemPlatform()
            let localTarPath = URL(fileURLWithPath: tarPath, relativeTo: .currentDirectory()).path
            let fm = FileManager.default
            if fm.fileExists(atPath: localTarPath) {
                try await ClientKernel.installKernelFromTar(tarFile: localTarPath, kernelFilePath: binaryPath, platform: platform, force: force)
                return
            }
            guard let remoteURL = URL(string: tarPath) else {
                throw ContainerizationError(.invalidArgument, message: "invalid remote URL '\(tarPath)' for argument '--tar'. Missing protocol?")
            }
            try await Self.downloadAndInstallWithProgressBar(tarRemoteURL: remoteURL.absoluteString, kernelFilePath: binaryPath, platform: platform, force: force)
        }

        private func getSystemPlatform() throws -> SystemPlatform {
            switch arch {
            case "arm64":
                return .linuxArm
            case "amd64":
                return .linuxAmd
            default:
                throw ContainerizationError(.unsupported, message: "unsupported architecture \(arch)")
            }
        }

        static func downloadAndInstallWithProgressBar(tarRemoteURL: String, kernelFilePath: String, platform: SystemPlatform = .current, force: Bool) async throws {
            let progressConfig = try ProgressConfig(
                showTasks: true,
                totalTasks: 2
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            try await ClientKernel.installKernelFromTar(tarFile: tarRemoteURL, kernelFilePath: kernelFilePath, platform: platform, progressUpdate: progress.handler, force: force)
            progress.finish()
        }

    }
}
