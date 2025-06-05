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

import ArgumentParser
import ContainerClient
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

extension Application {
    struct KernelSet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the default kernel"
        )

        @Option(name: .customLong("binary"), help: "Path to the binary to set as the default kernel. If used with --tar, this points to a location inside the tar")
        var binaryPath: String? = nil

        @Option(name: .customLong("tar"), help: "Filesystem path or remote URL to a tar ball that contains the kernel to use")
        var tarPath: String? = nil

        @Option(name: .customLong("arch"), help: "The architecture of the kernel binary. One of (amd64, arm64)")
        var architecture: String = ContainerizationOCI.Platform.current.architecture.description

        @Flag(name: .customLong("recommended"), help: "Download and install the recommended kernel as the default. This flag ignores any other arguments")
        var recommended: Bool = false

        func run() async throws {
            if recommended {
                let url = ClientDefaults.get(key: .defaultKernelURL)
                let path = ClientDefaults.get(key: .defaultKernelBinaryPath)
                print("Installing the recommended kernel from \(url)...")
                try await Self.downloadAndInstallWithProgressBar(tarRemoteURL: url, kernelFilePath: path)
                return
            }
            guard tarPath != nil else {
                return try await self.setKernelFromBinary()
            }
            try await self.setKernelFromTar()
        }

        private func setKernelFromBinary() async throws {
            guard let binaryPath else {
                throw ArgumentParser.ValidationError("Missing argument '--binary'")
            }
            let absolutePath = URL(fileURLWithPath: binaryPath, relativeTo: .currentDirectory()).absoluteURL.absoluteString
            let platform = try getSystemPlatform()
            try await ClientKernel.installKernel(kernelFilePath: absolutePath, platform: platform)
        }

        private func setKernelFromTar() async throws {
            guard let binaryPath else {
                throw ArgumentParser.ValidationError("Missing argument '--binary'")
            }
            guard let tarPath else {
                throw ArgumentParser.ValidationError("Missing argument '--tar")
            }
            let platform = try getSystemPlatform()
            let localTarPath = URL(fileURLWithPath: tarPath, relativeTo: .currentDirectory()).absoluteString
            let fm = FileManager.default
            if fm.fileExists(atPath: localTarPath) {
                try await ClientKernel.installKernelFromTar(tarFile: localTarPath, kernelFilePath: binaryPath, platform: platform)
                return
            }
            guard let remoteURL = URL(string: tarPath) else {
                throw ContainerizationError(.invalidArgument, message: "Invalid remote URL '\(tarPath)' for argument '--tar'. Missing protocol?")
            }
            try await Self.downloadAndInstallWithProgressBar(tarRemoteURL: remoteURL.absoluteString, kernelFilePath: binaryPath, platform: platform)
        }

        private func getSystemPlatform() throws -> SystemPlatform {
            switch architecture {
            case "arm64":
                return .linuxArm
            case "amd64":
                return .linuxAmd
            default:
                throw ContainerizationError(.unsupported, message: "Unsupported architecture \(architecture)")
            }
        }

        public static func downloadAndInstallWithProgressBar(tarRemoteURL: String, kernelFilePath: String, platform: SystemPlatform = .current) async throws {
            let progressConfig = try ProgressConfig(
                showTasks: true,
                totalTasks: 2
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            try await ClientKernel.installKernelFromTar(tarFile: tarRemoteURL, kernelFilePath: kernelFilePath, platform: platform, progressUpdate: progress.handler)
            progress.finish()
        }

    }
}
