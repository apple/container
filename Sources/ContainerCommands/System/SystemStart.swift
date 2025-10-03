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

import ArgumentParser
import ContainerClient
import ContainerPersistence
import ContainerPlugin
import ContainerizationError
import Foundation
import TerminalProgress

extension Application {
    public struct SystemStart: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start `container` services"
        )

        @Option(
            name: .shortAndLong,
            help: "Path to the root directory for application data",
            transform: { URL(filePath: $0) })
        var appRoot = ApplicationRoot.defaultURL

        @Option(
            name: .long,
            help: "Path to the root directory for application executables and plugins",
            transform: { URL(filePath: $0) })
        var installRoot = InstallRoot.defaultURL

        @Flag(
            name: .long,
            inversion: .prefixedEnableDisable,
            help: "Specify whether the default kernel should be installed or not (default: prompt user)")
        var kernelInstall: Bool?

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            // Without the true path to the binary in the plist, `container-apiserver` won't launch properly.
            // TODO: Can we use the plugin loader to bootstrap the API server?
            let executableUrl = CommandLine.executablePathUrl
                .deletingLastPathComponent()
                .appendingPathComponent("container-apiserver")
                .resolvingSymlinksInPath()

            var args = [executableUrl.absolutePath()]

            if global.debug {
                args.append("--debug")
            }

            args.append("start")
            let apiServerDataUrl = appRoot.appending(path: "apiserver")
            try! FileManager.default.createDirectory(at: apiServerDataUrl, withIntermediateDirectories: true)
            var env = ProcessInfo.processInfo.environment.filter { key, _ in
                key.hasPrefix("CONTAINER_")
            }
            env[ApplicationRoot.environmentName] = appRoot.path(percentEncoded: false)
            env[InstallRoot.environmentName] = installRoot.path(percentEncoded: false)

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
            var pullCommand = try ImagePull.parse()
            pullCommand.reference = dep.source
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
            let defaultKernelBinaryPath = DefaultsStore.get(key: .defaultKernelBinaryPath)

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
            try await KernelSet.downloadAndInstallWithProgressBar(tarRemoteURL: defaultKernelURL, kernelFilePath: defaultKernelBinaryPath, force: true)
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
                return DefaultsStore.get(key: .defaultInitImage)
            case .kernel:
                return DefaultsStore.get(key: .defaultKernelURL)
            }
        }
    }
}
