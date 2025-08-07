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
import ContainerPlugin
import ContainerizationError
import Foundation
import TerminalProgress

extension Application {
    struct SystemStart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start `container` services"
        )

        @Option(name: .shortAndLong, help: "Path to the `container-apiserver` binary")
        var path: String = Bundle.main.executablePath ?? ""

        @Option(
            name: .shortAndLong,
            help: "Application data directory",
            transform: { URL(filePath: $0) })
        var appRoot: URL = ApplicationRoot.defaultURL

        @Flag(name: .long, help: "Enable debug logging for the runtime daemon.")
        var debug = false

        @Flag(
            name: .long, inversion: .prefixedEnableDisable,
            help: "Specify whether the default kernel should be installed or not. The default behavior is to prompt the user for a response.")
        var kernelInstall: Bool?

        func run() async throws {
            // Without the true path to the binary in the plist, `container-apiserver` won't launch properly.
            let executableUrl = URL(filePath: path)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("container-apiserver")

            var args = [executableUrl.absolutePath()]

            if debug {
                args.append("--debug")
            }

            let apiServerDataUrl = appRoot.appending(path: "apiserver")
            try! FileManager.default.createDirectory(at: apiServerDataUrl, withIntermediateDirectories: true)
            var env = ProcessInfo.processInfo.environment.filter { key, _ in
                key.hasPrefix("CONTAINER_")
            }
            env["CONTAINER_APP_ROOT"] = appRoot.path(percentEncoded: false)

            let logURL = apiServerDataUrl.appending(path: "apiserver.log")
            let plist = LaunchPlist(
                label: "com.apple.container.apiserver",
                arguments: args,
                environment: env,
                limitLoadToSessionType: [.Aqua, .Background, .System],
                runAtLoad: true,
                stdout: logURL.path,
                stderr: logURL.path,
                machServices: ["com.apple.container.apiserver"]
            )

            let plistURL = apiServerDataUrl.appending(path: "apiserver.plist")
            let data = try plist.encode()
            try data.write(to: plistURL)

            try ServiceManager.register(plistPath: plistURL.path)

            // Now ping our friendly daemon. Fail if we don't get a response.
            do {
                print("Verifying apiserver is running...")
                _ = try await ClientHealthCheck.ping(timeout: .seconds(10))
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to get a response from apiserver: \(error)"
                )
            }

            if await !initImageExists() {
                try? await installInitialFilesystem()
            }

            guard await !kernelExists() else {
                return
            }
            try await installDefaultKernel()
        }

        private func installInitialFilesystem() async throws {
            let dep = Dependencies.initFs
            let pullCommand = ImagePull(reference: dep.source)
            print("Installing base container filesystem...")
            do {
                try await pullCommand.run()
            } catch {
                log.error("Failed to install base container filesystem: \(error)")
            }
        }

        private func installDefaultKernel() async throws {
            let kernelDependency = Dependencies.kernel
            let defaultKernelURL = kernelDependency.source
            let defaultKernelBinaryPath = ClientDefaults.get(key: .defaultKernelBinaryPath)

            var shouldInstallKernel = false
            if kernelInstall == nil {
                print("No default kernel configured.")
                print("Install the recommended default kernel from [\(kernelDependency.source)]? [Y/n]: ", terminator: "")
                guard let read = readLine(strippingNewline: true) else {
                    throw ContainerizationError(.internalError, message: "Failed to read user input")
                }
                guard read.lowercased() == "y" || read.count == 0 else {
                    print("Please use the `container system kernel set --recommended` command to configure the default kernel")
                    return
                }
                shouldInstallKernel = true
            } else {
                shouldInstallKernel = kernelInstall ?? false
            }
            guard shouldInstallKernel else {
                return
            }
            print("Installing kernel...")
            try await KernelSet.downloadAndInstallWithProgressBar(tarRemoteURL: defaultKernelURL, kernelFilePath: defaultKernelBinaryPath)
        }

        private func initImageExists() async -> Bool {
            do {
                let img = try await ClientImage.get(reference: Dependencies.initFs.source)
                let _ = try await img.getSnapshot(platform: .current)
                return true
            } catch {
                return false
            }
        }

        private func kernelExists() async -> Bool {
            do {
                try await ClientKernel.getDefaultKernel(for: .current)
                return true
            } catch {
                return false
            }
        }
    }

    private enum Dependencies: String {
        case kernel
        case initFs

        var source: String {
            switch self {
            case .initFs:
                return ClientDefaults.get(key: .defaultInitImage)
            case .kernel:
                return ClientDefaults.get(key: .defaultKernelURL)
            }
        }
    }
}
